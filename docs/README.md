# Series9Identity 컨트랙트 문서

`src/` 아래 모든 컨트랙트의 기능과 구현 상태를 정리한 문서입니다.
모든 핵심 컨트랙트는 **UUPS + ERC1967Proxy** 업그레이드 패턴(`_authorizeUpgrade onlyOwner`)을 사용합니다.

SER9 토큰 / 스테이킹 문서는 [SERIES9](https://github.com/PIXELZX0/SERIES9) 레포에 있습니다.

## 컨트랙트 목록

| 컨트랙트 | 파일 | 라인 수 | 역할 |
|----------|------|--------:|------|
| `Series9Identity` | [`src/Series9Identity.sol`](../src/Series9Identity.sol) | 1,380 | 1 주소당 하나의 identity ERC721 + handle 기반 결제 + 지갑 팩토리 + 에스크로 전송 |
| `Series9IdentityWallet` | [`src/Series9IdentityWallet.sol`](../src/Series9IdentityWallet.sol) | 153 | identity별 스마트 어카운트 지갑 (execute/배포, NFT 귀속 권한, 허용목록 업그레이드) |
| `Series9IdentityWalletV2` | [`src/Series9IdentityWalletV2.sol`](../src/Series9IdentityWalletV2.sol) | — | 지갑 로직 v2 — ERC-1271 `isValidSignature` 추가 |
| `Series9IdentityRenderer` | [`src/Series9IdentityRenderer.sol`](../src/Series9IdentityRenderer.sol) | 1,150 | 온체인 SVG/JSON 메타데이터 렌더러 (Identity의 base) |

## 개별 문서

- [`DeveloperGuide.md`](./DeveloperGuide.md) — **개발자용 사용 가이드** (Identity/Wallet 통합 방법, cast/viem 예시)
- [`Series9Identity.md`](./Series9Identity.md) — Identity NFT + Payment + 지갑 팩토리/에스크로 전송
- [`Series9IdentityWallet.md`](./Series9IdentityWallet.md) — identity별 스마트 어카운트 지갑
- [`Series9IdentityRenderer.md`](./Series9IdentityRenderer.md) — On-chain SVG 렌더러

## 구현 상태 한눈에 보기

| 영역 | 상태 |
|------|------|
| Identity NFT mint/profile/handle | 완전 구현 |
| Identity 보상 분배 (reputation 가중) | 완전 구현 |
| Identity handle 결제 (ERC20/MON) + 결제 요청 | 완전 구현 |
| Identity EIP-712 서명 결제 위임 | 완전 구현 |
| Identity별 스마트 어카운트 지갑 (execute/배포, NFT 귀속 권한) | 완전 구현 |
| 지갑 소유자 주도 업그레이드 (허용목록 + 다운그레이드 금지) | 완전 구현 |
| 지갑 ERC-1271 `isValidSignature` (로직 v2) | 완전 구현 |
| 정체성 에스크로 전송 (수락 + 6시간 지연 + 양측 취소, 전송 중 지갑 동결) | 완전 구현 |
| `tokenCreationFee` / `accruedCreationFees` / `sweepCreationFees` | **사용되지 않는 dead code** (managedToken 제거 후 잔재, sweep만 가능하나 누적 경로 없음) |
| `customAvatarSeed` (mapping + setter) | **deprecated** — 렌더러에서 무시함 (스토리지 호환성 유지용) |

자세한 구현/미구현 내역은 각 컨트랙트 문서의 **"구현 상태"** 섹션을 참조하세요.

## 업그레이드 구조

```
Series9Identity (UUPS)        <-- owner: deployer (또는 Safe)
  └─ self upgrade: upgradeToAndCall (onlyOwner)
  └─ Series9IdentityRenderer를 inherit (별도 proxy 없음)
  └─ initializeWalletFactory(bootstrapImpl) (reinitializer(3))로 지갑 팩토리 설정

Series9IdentityWallet (per-wallet UUPS)   <-- identity별 ERC1967 프록시, CREATE2(salt=tokenId)
  └─ upgrade 권한: 현 NFT 보유자 + Series9Identity 허용목록(setWalletImplApproved) + 다운그레이드 금지
```

## 빠른 시작

```bash
git clone --recurse-submodules https://github.com/PIXELZX0/SERIES9Identity.git
forge build
forge test -vv
```

SER9 토큰/스테이킹 컨트랙트는 테스트에서만 필요하며 `lib/series9` 서브모듈([SERIES9](https://github.com/PIXELZX0/SERIES9))로 참조합니다.
