# ACA graceful shutdown / readiness drain test

Azure Container Apps (ACA) のスケールイン時に、`Client -> Application Gateway -> ACA` 構成でどこまで ELB の connection draining に近い挙動を再現できるかを確認するための最小構成 Repo です。

この Repo は次を提供します。

- Bicep による Azure リソース作成
- `SIGTERM` を受けたときの graceful shutdown / readiness drain を観測しやすい Node.js アプリ
- 長時間リクエスト・継続短時間リクエスト・スケールイン・単一リビジョン更新の再現スクリプト
- README だけで最初から最後まで追える実行手順

> 参照は Microsoft Learn を優先しています。特に `SIGTERM` と 30 秒既定の終了猶予、readiness probe の意味、single revision での traffic cutover、Application Gateway + ACA 構成については、README 末尾の公式リンクを参照してください。

## 結論サマリー

- **ACA 単体でできること**: `SIGTERM` に反応してアプリが終了処理を行うこと、`terminationGracePeriodSeconds` の範囲内で既存処理の完了を待つこと、readiness probe を fail させて replica を ready から外すこと。
- **アプリ実装が必要なこと**: `SIGTERM` 受信時のログ出力、readiness fail への切替、必要に応じた新規受付拒否、進行中リクエスト数の可視化。
- **Application Gateway を前段に置く場合の注意点**: Application Gateway 側のバックエンド正常性評価が ACA readiness の変化を追従するまで短い遅延があり得るため、readiness fail と同時にアプリ側でも新規受付拒否を有効にしておくと安全です。
- **ELB 的な draining と完全同等か**: **完全同等ではなく近似実現**です。ACA は `SIGTERM` と readiness probe を使ってかなり近い動作を作れますが、LB からの即時除外を単独プロパティ 1 つで保証するわけではないため、アプリ実装を組み合わせる前提です。

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
│   ├── deploy-app.sh
│   ├── deploy-bootstrap.sh
│   ├── query-logs.sh
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
- Application Gateway の probe が追従すると対象 replica への新規流入が止まる
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
cd /home/runner/work/aca-graceful-shutdown-drain-test/aca-graceful-shutdown-drain-test/app
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

cd /home/runner/work/aca-graceful-shutdown-drain-test/aca-graceful-shutdown-drain-test
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

### パターン A (readiness 制御なし)

```bash
./scripts/deploy-app.sh "$RESOURCE_GROUP" "$PREFIX" v1 30 false Single
```

### パターン B (readiness drain あり)

```bash
./scripts/deploy-app.sh "$RESOURCE_GROUP" "$PREFIX" v1 120 true Single
```

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

### 成功例 (パターン B)

- 同一 replica で次の順にログが出る
  1. `shutdown.signal`
  2. `readiness.changed` (`ready=false`)
  3. その後は新規 `request.start` が止まる、または少数の `request.rejected` のみ
  4. 既存 long request の `request.end`
  5. `shutdown.exit`
- Application Gateway backend health が unhealthy に遷移
- `terminationGracePeriodSeconds` の範囲内で long request が完了

### 失敗例

- `SIGTERM` 後も対象 replica に継続的に新規 `request.start` が入る
- 進行中 long request が `request.end` を出さずに途切れる
- grace period を超えて `shutdown.exit` が出ず、強制終了が疑われる

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

- Application lifecycle management in Azure Container Apps  
  https://learn.microsoft.com/en-us/azure/container-apps/application-lifecycle-management
- Health probes in Azure Container Apps  
  https://learn.microsoft.com/en-us/azure/container-apps/health-probes
- Update and deploy changes in Azure Container Apps  
  https://learn.microsoft.com/en-us/azure/container-apps/revisions
- Microsoft.App/containerApps template reference  
  https://learn.microsoft.com/en-us/azure/templates/microsoft.app/containerapps
- Protect Azure Container Apps with Application Gateway / WAF  
  https://learn.microsoft.com/en-us/azure/container-apps/waf-app-gateway
