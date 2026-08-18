# SERIES9Identity

Foundry 기반의 Series9 identity NFT + identity 지갑 컨트랙트입니다.
모든 핵심 컨트랙트는 `UUPS + ERC1967Proxy` 기반 업그레이드 구조를 사용합니다.

## 핵심 개념

- `Series9Identity`:
  - SER9 mint fee를 스테이킹하는 UUPS 기반 identity NFT (1 주소당 1개)
  - Identity 스테이킹 보상은 reputation score 비율로 분배 (기본값: Human 9, AI 1)
  - 고유 payment handle 기반 ERC20/MON 송금 및 결제 요청 지원
  - identity별 스마트 어카운트 지갑 팩토리 (CREATE2, salt = tokenId)
  - identity 소유권 에스크로 전송 (수락 + 6시간 지연 + 양측 취소, 전송 중 지갑 동결)
- `Series9IdentityWallet` / `Series9IdentityWalletV2`:
  - identity NFT 소유자만 `execute` / 배치 실행 / 컨트랙트 배포 가능
  - 업그레이드 권한: 현 NFT 보유자 + Identity 허용목록(`setWalletImplApproved`) + 다운그레이드 금지
  - v2는 ERC-1271 `isValidSignature` 추가
  - `Series9IdentityRenderer`: 온체인 black/white/gold identity card SVG/JSON 메타데이터 렌더러
  - 각 identity owner는 `setImageUrl`로 `https://`, `http://`, `ipfs://`, `ar://` 사진 URL을 설정하거나 비울 수 있음

## 주요 규칙

1. Identity NFT 보상은 각 identity의 reputation score 비율로 계산되며, owner가 점수를 조정할 수 있음
2. Identity Payment는 현재 identity 소유자 본인이 실행할 때만 승인된 ERC20 또는 전송한 MON을 이동함
3. `Series9Identity`는 identity proxy owner(Safe)가 `upgradeToAndCall(...)`로 직접 업그레이드
4. 지갑 로직 업그레이드는 Identity owner가 `setWalletImplApproved`로 허용한 implementation만 가능

## 컨트랙트

- `src/Series9Identity.sol`
- `src/Series9IdentityRenderer.sol`
- `src/Series9IdentityWallet.sol`
- `src/Series9IdentityWalletV2.sol`

## 빠른 시작

```bash
git clone --recurse-submodules https://github.com/PIXELZX0/SERIES9Identity.git
cd SERIES9Identity
forge build
forge test -vv
```

`lib/series9`는 [SERIES9](https://github.com/PIXELZX0/SERIES9) 레포(SER9 토큰 + 스테이킹) 서브모듈입니다.
컨트랙트 자체는 SER9에 의존하지 않고 주소만 받지만, 통합 테스트에서 실제 구현이 필요해 참조합니다.
`remappings.txt`의 `series9/=lib/series9/src/`로 매핑됩니다.

서브모듈 없이 클론했다면:

```bash
git submodule update --init   # --recursive 불필요
```

## 배포

```bash
export PRIVATE_KEY=<PRIVATE_KEY>
export STAKING_PROXY=<STAKING_PROXY_ADDRESS>

forge script script/DeployIdentity.s.sol:DeployIdentity \
  --rpc-url <MONAD_RPC_URL> \
  --broadcast
```

업그레이드 스크립트:

- `script/UpgradeSeries9Identity.s.sol` — Identity implementation + 지갑 팩토리 부트스트랩
- `script/UpgradeIdentityWalletV2.s.sol` — 지갑 로직 v2 배포 + 허용목록 등록
- `script/UpgradeIdentityMetadata.s.sol` — photo URL 메타데이터 카드 렌더러 업그레이드

## GitHub Actions

| 워크플로 | 트리거 | 하는 일 |
|---|---|---|
| `.github/workflows/ci.yml` | push(main) / PR | `forge build` + `forge test` |
| `.github/workflows/release-monad-mainnet-upgrade.yml` | release published / 수동 | Identity implementation 배포 + Sourcify/SocialScan 검증 + Safe Transaction Builder JSON 생성 |

릴리즈 워크플로는 온체인 bytecode를 비교해 **변경된 컨트랙트만** 배포하고,
지갑 팩토리가 아직 초기화되지 않았으면 부트스트랩 implementation 배포 + `initializeWalletFactory` 트랜잭션을 Safe 배치에 추가합니다.

필수 GitHub Secrets:

- `MONAD_RPC_URL`
- `PRIVATE_KEY`
- `IDENTITY_PROXY`
- `SUBMODULE_TOKEN` — `lib/series9`가 private 레포라 checkout에 필요한 PAT (repo scope)

선택 GitHub Secrets:

- `IDENTITY_UPGRADE_DATA` (기존 프록시에 Payment 초기화가 필요하면 `0x38cdfc0c`, `initializePayment()`)

선택 GitHub Variables:

- `SKIP_VERIFY` (`true`/`false`, 기본값 `false`)

## 문서

- [`docs/README.md`](docs/README.md) — 컨트랙트 목록 + 구현 상태
- [`docs/DeveloperGuide.md`](docs/DeveloperGuide.md) — 통합 가이드 (cast/viem 예시)

## 관련 레포

- [SERIES9](https://github.com/PIXELZX0/SERIES9) — SER9 토큰 + 스테이킹
- [SERIES9DEX](https://github.com/PIXELZX0/SERIES9DEX) — DEX (현물/오더북/선물)
- [SERIES9_Front](https://github.com/PIXELZX0/SERIES9_Front) — 웹 프론트엔드
