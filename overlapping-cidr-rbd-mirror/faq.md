# FAQ

`overlapping-cidr-rbd-mirror` の構築やデバッグで詰まりやすい点をまとめます。

## WSL mirrored networking で libvirt DHCP が起動しない

libvirt network の起動時に以下が出る場合があります。

```text
dnsmasq: failed to bind DHCP server socket: Address already in use
```

WSL mirrored networking では、Windows 側で DHCP port が使われていて Linux 側 `ss` には見えないことがあります。
Windows ユーザーの `.wslconfig` に以下を設定し、Windows 側で `wsl --shutdown` してから再実行してください。

```ini
[wsl2]
networkingMode=mirrored

[experimental]
ignoredPorts=53,67,68,547
```

## KVM permission error が出る

以下が出る場合は、minikube/Submariner ではなく host の `/dev/kvm` 権限または WSL の nested virtualization 露出の問題です。

```text
Could not access KVM kernel module: Permission denied
qemu-system-x86_64: -accel kvm: failed to initialize kvm: Permission denied
```

`kvm-ok` は現在の shell user の確認で、libvirt が起動する QEMU 実行 user とは別です。
`make clusters` は事前処理として libvirt の QEMU user を `kvm` group に入れ、`/etc/libvirt/qemu.conf` の `group = "kvm"` を設定します。
WSL では `/dev/kvm` の group が `/etc/group` に存在しない numeric GID に戻ることがあるため、`/dev/kvm` の group/mode も `kvm:0660` に補正します。
その後、libvirt を再起動し、同じ QEMU user で `qemu-system-x86_64 -accel kvm` を probe します。

## qemu builtin NAT では成功条件にならない

Submariner dataplane の検証には、各 Minikube VM が distinct で相互到達可能な advertised gateway IP を持つ必要があります。

`kvm2` では minikube profile ごとの libvirt network IP を gateway `PublicIP` として広告します。
これは Submariner tunnel 用の reachable underlay です。

qemu builtin NAT 構成では、両 endpoint が `10.0.2.15` / 同一 PublicIP に見えるため tunnel は確立しません。
この lab は qemu builtin を成功条件にしません。
`make clusters` は `kvm2` 以外の driver、`10.0.2.15`、または同一 underlay CIDR 上の node InternalIP を検出したら失敗します。

## Node InternalIP は同じ CIDR なのに直接通信しないのか

この lab では Node `InternalIP` は両クラスタとも `172.16.128.0/22` にします。
ただしこれは各 VM 内の dummy interface 上の非共有 network です。

- source cluster (`cluster-a`): `172.16.130.11`
- recovery cluster (`cluster-b`): `172.16.130.12`

CIDR としては重複しますが、共有 L2/L3 network ではないため、そのままでは互いに通信できません。
Submariner tunnel 用の reachable underlay は minikube profile ごとの libvirt network IP を使います。

## `subctl show connections` の `REMOTE IP` は何か

`subctl show connections` の `REMOTE IP` は Submariner Gateway の advertised PublicIP です。
この lab では各 Minikube profile の libvirt network IP です。
Globalnet IP ではありません。

```text
source cluster gateway underlay: <cluster-a-profile-ip>
recovery cluster gateway underlay: <cluster-b-profile-ip>
```

`make submariner` は join 前に gateway node へ以下を annotate し、`subctl join --natt=false` を渡します。

```bash
gateway.submariner.io/public-ip=ipv4:<profile-ip>
```

## iptables と nftables のどちらを使うのか

Submariner 0.23 系は nftables packet filter driver をデフォルトで使いますが、この lab では `SUBMARINER_USE_NFTABLES=false` をデフォルトにして iptables backend を使います。

理由は、Minikube VM の Buildroot 環境で nftables table 作成ができるかは node VM の kernel/userland 依存だからです。
node 側の nftables が使えることを確認できた場合は、`SUBMARINER_USE_NFTABLES=true` に変更できます。

host 側の NAT/forwarding repair は `iptables` があれば iptables rule を入れ、`nft` があれば nftables rule も補助的に入れます。

## gateway health check を無効にしている理由

Minikube node 上では gateway health check が GlobalCIDR の health check IP へ packet を送る際に、以下で失敗する場合があります。

```text
sendmsg: operation not permitted
```

このため、デフォルトでは `subctl join --health-check=false` を渡します。
tunnel 成立は `subctl show connections` と `make globalnet-test` の Global IP 通信で確認します。

## route-agent が CNI interface を見つけられない

Submariner route-agent は `POD_CIDR` に含まれる IP を持つ CNI interface を node 上で探します。

この lab では以下を `POD_CIDR=192.168.200.0/22` に合わせます。

- minikube kubeadm `pod-network-cidr`
- controller-manager `cluster-cidr`
- `node-cidr-mask-size-ipv4`
- bridge CNI config の subnet
- `subctl join --clustercidr`

ここが実 CNI subnet とずれると route-agent log に以下が出て、接続確認まで進みません。

```text
unable to find a CNI Interface which has an IP from the cluster CIDRs
```

`make clusters` は node `.spec.podCIDR` と実 Pod IP が `POD_CIDR` に入ることも確認します。

## `globalnet-client` の DNS 確認は何を見るべきか

`make globalnet-test` の本判定は `wget` による HTTP 到達です。
BusyBox `nslookup` は `No answer` を出しても exit code 0 になることがあるため、診断ログとしてだけ扱います。

```bash
kubectl --context cluster-b -n globalnet-test exec globalnet-client -- wget -qO- --timeout=10 http://echo.globalnet-test.svc.clusterset.local
```

`BUSYBOX_IMAGE` を差し替える場合は、少なくとも `wget` が入っている image を指定してください。
`nslookup` が入っていれば追加診断に使えます。

以下のようなエラーが出る image は DNS 診断には使えません。

```text
exec: "nslookup": executable file not found in $PATH
```

デフォルトでは `registry.k8s.io/e2e-test-images/busybox:1.29-4` を使います。

## `default` namespace に何も見えない

`make submariner` のゴール時点で、`default` namespace にはリソースが見えません。
確認は `-A` か namespace 指定で行ってください。

`cluster-a`:

- `submariner-operator`: `submariner-operator-*`, `submariner-gateway-*`, `submariner-routeagent-*`
- `lighthouse`: service-discovery 関連リソース

`cluster-b`:

- `submariner-operator`: `submariner-operator-*`, `submariner-gateway-*`, `submariner-routeagent-*`
- `submariner-k8s-broker`: broker 関連リソース
- `lighthouse`: service-discovery 関連リソース

よく使う確認コマンド:

```bash
minikube -p cluster-a kubectl -- get ns
minikube -p cluster-a kubectl -- get pods -A
minikube -p cluster-a kubectl -- get pods -n submariner-operator
minikube -p cluster-b kubectl -- get pods -n submariner-k8s-broker
minikube -p cluster-b kubectl -- get pods -A
minikube -p cluster-b kubectl -- get pods -n submariner-operator
subctl show gateways --context cluster-a
subctl show connections --context cluster-a
```
