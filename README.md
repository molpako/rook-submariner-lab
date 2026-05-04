# Rook + Submariner Lab

Rook/Ceph と Submariner を使ったマルチクラスタ実験をまとめるためのリポジトリです。
各実験はルート直下の独立ディレクトリとして管理し、README、スクリプト、マニフェストはその中に置きます。

## Experiments

| Directory | Description | Status |
| --- | --- | --- |
| `overlapping-cidr-rbd-mirror` | 同一ホスト上の 2 つの Minikube クラスタで、overlapping Pod/Service CIDR を Submariner Globalnet で扱いながら Rook/Ceph の RBD mirroring を試す | validated |

## Repository Policy

- ルート README は実験一覧と全体方針だけを書く
- 個別の手順、前提、制約、確認項目は各実験ディレクトリの README に置く
- 再実行したい操作はなるべく `scripts/` に寄せる
- クラスタ固有値はマニフェストへ直書きせず、`mise.toml` とテンプレートから注入する

## Quick Start

最初の実験は [`overlapping-cidr-rbd-mirror`](./overlapping-cidr-rbd-mirror) です。

```bash
mise trust
cd overlapping-cidr-rbd-mirror
make clean-clusters && make all
```

## Why This Layout

このリポジトリでは今後、Rook/Submariner まわりの検証を増やしていく予定です。
そのためルートを単一シナリオ専用の README にはせず、実験カタログとして扱います。
