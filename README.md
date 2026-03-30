# ACA graceful shutdown / readiness drain test

Azure Container Apps (ACA) のスケールイン時に、`Client -> Application Gateway -> ACA` 構成で Pattern B の graceful shutdown / readiness drain をどう成立させるかを確認するための最小構成 Repo です。

この Repo は次を提供します。

- Bicep による Azure リソース作成
- `SIGTERM` を受けたときの graceful shutdown / readiness drain を観測しやすい Node.js アプリ
- 同一 revision autoscaler shrink・継続短時間リクエスト・単一リビジョン更新の再現スクリプト
- README だけで最初から最後まで追える実行手順

> 参照は Microsoft Learn を優先しています。特に `SIGTERM` と 30 秒既定の終了猶予、readiness probe の意味、single revision での traffic cutover、Application Gateway + ACA 構成については、README 末尾の公式リンクを参照してください。

## 結論サマリー

- **最終的に確認できたこと**: same-revision autoscaler shrink と Application Gateway 経由の request 完走は同じ run の中で両立できます。
- **この Repo で確立した Pattern B の構成**: `DRAIN_READINESS_ON_SIGTERM=true`, `REJECT_NEW_REQUESTS_ON_DRAIN=true`, `terminationGracePeriodSeconds=120`, `revisionMode=Single`, `concurrentRequests=5`, `minReplicas=1`, `maxReplicas=5`。
- **検証の成立条件**: active revision が変わらないこと、request が `200` で完走すること、removed replica で `shutdown.signal`, `readiness.changed`, `shutdown.exit` が取れること。
- **ACA 単体でできること**: `SIGTERM` に反応して終了処理を行うこと、`terminationGracePeriodSeconds` の範囲内で既存処理の完了を待つこと、readiness probe を fail させて replica を ready から外すこと。
- **アプリ実装が必要なこと**: `SIGTERM` 受信時のログ出力、readiness fail への切替、必要に応じた新規受付拒否、進行中リクエスト数の可視化。
- **ELB 的な draining と完全同等か**: **完全同等ではなく近似実現**です。ACA は `SIGTERM` と readiness probe を使ってかなり近い動作を作れますが、LB からの即時除外を単独プロパティ 1 つで保証するわけではないため、アプリ実装を組み合わせる前提です。

最終結果だけ確認したい場合は [reports/pattern-b-same-revision-autoscale-report-20260330.md](reports/pattern-b-same-revision-autoscale-report-20260330.md) を参照してください。

## Repo 構成

```text
.
├── app/
│   ├── package.json
│   ├── server.js
│   └── server.test.js
├── infra/
│   ├── bootstrap.bicep
│   ├── foundation.bicep
│   └── main.bicep
├── scripts/
│   ├── build-image.sh
│   ├── autoscale-shrink-test.sh
│   ├── deploy-app.sh
│   ├── deploy-bootstrap.sh
│   ├── query-logs.sh
│   ├── query-request-correlation.sh
│   ├── revision-test.sh
│   ├── run-long-requests.sh
│   ├── run-short-requests.sh
│   └── scale-in-test.sh
└── Dockerfile
```

## アプリ仕様

エンドポイント:

- `/work?duration=NN`
  - `NN` 秒だけ処理を継続する疑似ロングリクエスト
- `/`
  - `duration=0` の簡易応答
- `/health/live`
  - liveness probe 用
- `/health/ready`
  - readiness probe 用
- `/state`
  - 現在の replica 状態を JSON で返却

出力ログ(JSON 1 行):

- `server.started`
- `request.start`
- `request.end`
- `request.rejected`
- `shutdown.signal`
- `readiness.changed`
- `shutdown.waiting`
- `shutdown.exit`

主な環境変数:

- `DRAIN_READINESS_ON_SIGTERM=true|false`
- `REJECT_NEW_REQUESTS_ON_DRAIN=true|false`
- `EXIT_ON_IDLE_AFTER_SIGNAL=true|false`
- `PORT=8080`

### パターン A: readiness 制御なし

```text
DRAIN_READINESS_ON_SIGTERM=false
REJECT_NEW_REQUESTS_ON_DRAIN=false
terminationGracePeriodSeconds=30 or 120
```

想定観測:

- `SIGTERM` は出る
- readiness は healthy のまま
- LB / App Gateway からの新規流入停止がどこまで起きるかはプラットフォーム任せ
- 既存処理は grace period 内なら完了し得る

### パターン B: readiness drain あり

```text
DRAIN_READINESS_ON_SIGTERM=true
REJECT_NEW_REQUESTS_ON_DRAIN=true
terminationGracePeriodSeconds=30 or 120
```

想定観測:

- `SIGTERM` 後すぐ `readiness.changed` が出る
- `/health/ready` が `503` になる
- backend health の追従後に対象 replica への新規流入が止まりやすくなる
- 万一リクエストが到達しても `request.rejected` で `503` を返せる
- 進行中リクエストは grace period 内で完了を待てる

## 0. 前提条件

以下がローカルに必要です。

- Azure CLI 2.84+
- Bicep (`az bicep install` 済み)
- Docker を使わずに `az acr build` を使うため、Azure へログイン済みであること
- `jq`, `curl`, `bash`

## 1. ローカルでアプリを確認

```bash
cd app
npm test
npm start
```

別ターミナル:

```bash
curl http://127.0.0.1:8080/health/ready
curl 'http://127.0.0.1:8080/work?duration=5'
```

`Ctrl+C` または `kill -TERM <pid>` の後、ログで `shutdown.signal -> readiness.changed -> shutdown.waiting -> shutdown.exit` を確認します。

## 2. Azure へ bootstrap デプロイ

以下では `PREFIX=acadrain` を例にします。名前衝突を避けるため短い一意 prefix を使ってください。

```bash
export SUBSCRIPTION_ID='<your-subscription-id>'
export LOCATION='japaneast'
export PREFIX='acadrain'
export RESOURCE_GROUP="${PREFIX}-rg"

cd <repo-root>
./scripts/deploy-bootstrap.sh "$SUBSCRIPTION_ID" "$LOCATION" "$PREFIX" "$RESOURCE_GROUP"
```

この段階で作成されるもの:

- Resource Group
- Log Analytics Workspace
- Azure Container Registry
- Virtual Network
- ACA infrastructure subnet
- Application Gateway subnet
- Internal ACA Environment

出力値は `az deployment sub show` でも確認できます。

## 3. ACR に検証アプリ image を build

```bash
ACR_NAME=$(az acr list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv)
./scripts/build-image.sh "$RESOURCE_GROUP" "$ACR_NAME" v1
```

## 4. ACA App + Private DNS + Application Gateway をデプロイ

### 最終検証で使った推奨構成

元の目的に対して最終的に成立した構成は次です。

```bash
./scripts/deploy-app.sh "$RESOURCE_GROUP" "$PREFIX" v1 120 true Single 5 1 5 600
```

意味:

- `terminationGracePeriodSeconds=120`: 進行中リクエストに待機猶予を与える
- `DRAIN_READINESS_ON_SIGTERM=true`: SIGTERM 時に readiness を落とす
- `REJECT_NEW_REQUESTS_ON_DRAIN=true`: drain 中の新規受付をアプリ側でも止める
- `revisionMode=Single`: 検証対象を same-revision shrink に限定する
- `concurrentRequests=5`: probe 相当の定常トラフィックで無駄な scale-out を起こしにくくする
- `minReplicas=1`, `maxReplicas=5`: 同一 revision 内の autoscaler 増減を許可する

### パターン A (readiness 制御なし)

```bash
./scripts/deploy-app.sh "$RESOURCE_GROUP" "$PREFIX" v1 30 false Single
```

### パターン B (readiness drain あり)

```bash
./scripts/deploy-app.sh "$RESOURCE_GROUP" "$PREFIX" v1 120 true Single
```

### 同一 revision autoscaler shrink の前提

純粋な autoscaler shrink を見たい場合は、scale 設定を先に 1 回だけ作り、その後の試験中は `az containerapp update --min-replicas/--max-replicas` を呼ばないでください。

> この Repo の構成では ACA Environment 自体は internal ですが、Application Gateway から到達させる Container App の ingress は `external=true` にしています。ACA の `external=false` は「同一 Container Apps environment 内からのみ到達可能」の扱いであり、VNet 上の Application Gateway や VM からは到達できません。
> `concurrentRequests=1` は、この構成では低すぎます。Application Gateway の backend probe や readiness / liveness 系の定常アクセスまで scaler が拾い、アイドルなのに複数 replica から落ちなくなることがありました。

デプロイ後に接続先を取得します。

```bash
APP_NAME="${PREFIX}-app"
GATEWAY_IP=$(az network public-ip show --resource-group "$RESOURCE_GROUP" --name "${PREFIX}-agw-pip" --query ipAddress -o tsv)
APP_GATEWAY_URL="http://${GATEWAY_IP}"
ACA_FQDN=$(az containerapp show --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" --query properties.configuration.ingress.fqdn -o tsv)

echo "$APP_GATEWAY_URL"
echo "$ACA_FQDN"
```

## 5. 再現手順

### 5-1. 継続短時間リクエスト

```bash
./scripts/run-short-requests.sh "$APP_GATEWAY_URL" 0 1
```

### 5-2. 長時間リクエストを複数並列送信

```bash
./scripts/run-long-requests.sh "$APP_GATEWAY_URL" 45 4
```

### 5-3. スケールアウト後にスケールインを誘発

`main.bicep` は HTTP スケーラ (`concurrentRequests`) を設定しています。並列ロングリクエストで 2 replica 以上に増えた後、次で 1 replica に戻します。

```bash
./scripts/scale-in-test.sh "$RESOURCE_GROUP" "$APP_NAME" "$APP_GATEWAY_URL" 6
```

これは revision-scoped な設定更新を使うため、`Single` revision mode では pure autoscaler shrink の主検証ではなく比較用です。

### 5-3b. 同一 revision の autoscaler shrink を検証

純粋な autoscaler shrink を見たい場合は、負荷を止めるだけで縮退させます。

```bash
./scripts/autoscale-shrink-test.sh "$RESOURCE_GROUP" "$APP_NAME" "$APP_GATEWAY_URL" 6 0.2 0 60 2 900
```

流れ:

1. 短時間リクエストで scale-out させる
2. 短時間リクエストだけ止める
3. autoscaler が同一 revision 内で replica を減らすのを待つ
4. `longParallelism=0` のときは shrink 遅延の測定だけを行う

このときの観点:

- active revision が変わっていないこと
- replica 数だけが減っていること
- App Gateway backend health が `Healthy` を維持するか
- app log に `readiness.changed`, `shutdown.signal`, `shutdown.exit` が出るか

戻り値の JSON には次も含まれます。

- `loadStoppedAt`
- `firstScaleReductionAt`
- `loadStopReplicaCount`
- `peakReplicaCountAfterLoadStop`

これで、負荷停止から実際の shrink 開始までの遅延をまず 2〜3 回測れます。

### 5-3c. 遅延投入で App Gateway 完走と shrink を重ねる

本来の目的を検証するには、long request を極端に長くするのではなく、自然な shrink 窓に寄せて投入します。

まず `loadStoppedAt` から `firstScaleReductionAt` までの遅延を測り、その値に合わせて request 投入時刻を決めます。

```bash
./scripts/autoscale-shrink-test.sh "$RESOURCE_GROUP" "$APP_NAME" "$APP_GATEWAY_URL" 6 0.2 1 60 2 900 360
```

この例の意味:

- `longParallelism=1`: validation request を 1 本だけ流す
- `longDurationSeconds=60`: request 完走と shrink の両立確認に必要な長さだけを使う
- `delayBeforeLongSeconds=360`: 事前計測した shrink 遅延に合わせて request を遅延投入する

この Repo の主検証はこの手順です。判定の基本は次です。

- App Gateway 経由の long request が `200` で完走する
- app log に同じ `request.start` と `request.end` が出る
- 同じ試験窓で removed replica の `shutdown.signal`, `readiness.changed`, `shutdown.exit` が回収できる
- active revision が変わらない

### 5-4. 単一リビジョン更新 (パターン C)

```bash
./scripts/revision-test.sh "$RESOURCE_GROUP" "$APP_NAME"
```

`Single` revision mode のまま `TEST_MARKER` を更新し、新しい revision を作ります。readiness 成功後に traffic cutover されるかをログで確認します。

## 6. 何を観測するか

### Azure CLI

#### replica / revision 状態

```bash
az containerapp replica list --resource-group "$RESOURCE_GROUP" --name "$APP_NAME"   --query '[].{name:name,runningState:properties.runningState,createdTime:properties.createdTime}'

az containerapp revision list --resource-group "$RESOURCE_GROUP" --name "$APP_NAME"   --query '[].{name:name,active:properties.active,healthState:properties.healthState,trafficWeight:properties.trafficWeight}'
```

#### 最新ログの確認

```bash
az containerapp logs show --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" --follow
```

### Log Analytics

Workspace ID を取得し、`scripts/query-logs.sh` を使います。

```bash
WORKSPACE_ID=$(az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP" --workspace-name "${PREFIX}-law" --query customerId -o tsv)
./scripts/query-logs.sh "$WORKSPACE_ID" 1 shutdown.signal
```

App Gateway access log と app log を request 単位で突き合わせたい場合は、`scripts/query-request-correlation.sh` を使います。

```bash
WORKSPACE_ID=$(az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP" --workspace-name "${PREFIX}-law" --query customerId -o tsv)
./scripts/query-request-correlation.sh \
  "$WORKSPACE_ID" \
  8 \
  60 \
  long-1-1774858050860
```

このスクリプトは次を 1 つの JSON にまとめます。

- `AzureDiagnostics` の `ApplicationGatewayAccessLog`
- `ContainerAppConsoleLogs_CL` の `request.start` / `request.end`

直接 KQL を使う場合:

```kusto
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where Log_s has_any ('shutdown.signal', 'readiness.changed', 'request.start', 'request.end', 'request.rejected', 'shutdown.exit')
| project TimeGenerated, RevisionName_s, ReplicaName_s, Log_s
| order by TimeGenerated asc
```

### Portal

- Container App > **Revision management**: single revision cutover のタイミング
- Container App > **Replicas**: スケールイン対象 replica の消滅タイミング
- Application Gateway > **Backend health**: readiness fail 後に backend が unhealthy 扱いへ変化するか
- Log Analytics: `shutdown.signal` と `readiness.changed` の相関

## 7. 成功 / 失敗判定基準

### 成功例 (今回の最終目標)

- active revision が変わらない
- short load 停止後に replica 数だけが減る
- shrink 窓に寄せた validation request が App Gateway 経由で `200` 完走する
- app log に同じ request の `request.start` と `request.end` が出る
- removed replica で `shutdown.signal`, `readiness.changed`, `shutdown.exit` が出る
- public `/health/ready` が継続して `200` を返す

### 失敗例

- active revision が途中で変わる
- request が `200` で完走しない
- removed replica に shutdown 系イベントが出ない
- replica が減らず、same-revision shrink が確認できない

## 8. サンプルログ

### パターン B の期待ログ例

```json
{"timestamp":"2026-03-26T23:00:00.000Z","event":"shutdown.signal","replica":"aca-replica-a","pid":1,"readiness":true,"draining":true,"activeRequests":2,"signal":"SIGTERM","drainReadinessOnSigterm":true,"rejectNewRequestsOnDrain":true}
{"timestamp":"2026-03-26T23:00:00.001Z","event":"readiness.changed","replica":"aca-replica-a","pid":1,"readiness":false,"draining":true,"activeRequests":2,"ready":false,"reason":"SIGTERM"}
{"timestamp":"2026-03-26T23:00:02.010Z","event":"request.end","replica":"aca-replica-a","pid":1,"readiness":false,"draining":true,"activeRequests":0,"requestId":"long-1","durationSeconds":45,"elapsedMs":45008}
{"timestamp":"2026-03-26T23:00:02.011Z","event":"shutdown.exit","replica":"aca-replica-a","pid":1,"readiness":false,"draining":true,"activeRequests":0,"reason":"all-requests-finished"}
```

### パターン A の期待ログ例

```json
{"timestamp":"2026-03-26T23:10:00.000Z","event":"shutdown.signal","replica":"aca-replica-b","pid":1,"readiness":true,"draining":true,"activeRequests":1,"signal":"SIGTERM","drainReadinessOnSigterm":false,"rejectNewRequestsOnDrain":false}
{"timestamp":"2026-03-26T23:10:00.001Z","event":"readiness.unchanged","replica":"aca-replica-b","pid":1,"readiness":true,"draining":true,"activeRequests":1,"reason":"drain disabled by configuration"}
```

## 9. Bicep パラメータの要点

- `terminationGracePeriodSeconds`: `30` と `120` を切り替えて比較
- `drainReadinessOnSigterm`: `false` でパターン A、`true` でパターン B
- `revisionMode`: `Single` を既定値にし、パターン C をそのまま試せるようにしている
- `concurrentRequests`: HTTP スケールルールの閾値

## 10. 後片付け

```bash
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
```

## Microsoft Learn / 公式参照

- [Application lifecycle management in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/application-lifecycle-management)
- [Health probes in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/health-probes)
- [Update and deploy changes in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/revisions)
- [Microsoft.App/containerApps template reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.app/containerapps)
- [Protect Azure Container Apps with Application Gateway / WAF](https://learn.microsoft.com/en-us/azure/container-apps/waf-app-gateway)
