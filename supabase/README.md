# 미리봄 Supabase 백엔드

이 폴더는 git 에 커밋되는 **재현 가능한** 백엔드 정의입니다. 대시보드에서 손으로 표를
만들지 마세요. 누구든 같은 명령으로 동일한 스키마/정책을 재현할 수 있어야 합니다.

```
supabase/
├─ README.md
└─ migrations/
   ├─ 20260621000001_init_schema.sql   # 테이블/인덱스/트리거
   └─ 20260621000002_rls_policies.sql  # RLS 정책 + 토큰 교환 함수 + 대시보드 뷰
```

## 데이터 모델

| 테이블 | 역할 | 핵심 |
|---|---|---|
| `profiles` | 작가 프로필 | `auth.users` 와 1:1 |
| `documents` | 작업 원고 | **원본 마크다운**(`content_md`) 그대로 저장 — 렌더된 HTML 아님 |
| `shares` | 공유 스냅샷 | 공유 시점 마크다운을 **동결 복사** + 고유 `token` |
| `share_grants` | 열람 권한 | 토큰을 제시해 스냅샷을 연 (익명 포함) 사용자 기록 |
| `comments` | 익명 코멘트 | 스냅샷에 달림 |

> 화면 표시는 기존 미리봄 파서(`assemble()`)가 클라이언트에서 마크다운을 렌더합니다.
> DB 에는 항상 원본 마크다운만 둡니다.

## 접근 제어(RLS) 규칙

1. **작가는 자기 원고/대시보드만** — `documents`, `author_dashboard` 는 `owner_id = auth.uid()`.
2. **공유 토큰 보유자만 그 스냅샷을** — `redeem_share(token)` 으로 `share_grants` 를 받은 뒤에만 열람.
3. **익명 코멘트 작성자는 그 스냅샷 하나만** — grant 가 있는 스냅샷에만, 본인 명의로 읽기/쓰기.

비밀 토큰 검증은 RLS 만으로 안전하게 할 수 없어(행 열거 위험) `redeem_share()` **SECURITY DEFINER**
함수로 처리합니다(Supabase 표준 패턴).

### 클라이언트 접근 흐름 (공유 링크 방문자)

```
1. supabase.auth.signInAnonymously()        // 익명이라도 uid 확보
2. supabase.rpc('redeem_share', { p_token }) // 토큰 검증 → 스냅샷 반환 + grant 기록
3. 반환된 content_md 를 미리봄 파서로 렌더
4. comments 테이블에 읽기/쓰기 (grant 있는 스냅샷에만 허용됨)
```

## 적용 방법

### A) Supabase CLI (권장)

```bash
supabase link --project-ref <PROJECT_REF>   # 최초 1회
supabase db push                            # migrations/ 를 순서대로 적용
```

### B) psql 로 직접 (회사 서버/셀프호스팅 재현)

```bash
psql "$SUPABASE_DB_URL" -f supabase/migrations/20260621000001_init_schema.sql
psql "$SUPABASE_DB_URL" -f supabase/migrations/20260621000002_rls_policies.sql
```

`$SUPABASE_DB_URL` 등 값은 `.env` 에 둡니다(`.env.example` 참고). `.env` 는 커밋하지 않습니다.

## 대시보드에서 직접 해야 할 일 (코드로 못 하는 부분)

- [ ] 새 프로젝트 생성 후 **Project URL / anon key** 를 `.env` 에 기입
- [ ] **Authentication → Providers**: Email, Google 켜기 (Kakao 쓸 경우 Kakao 켜고 앱 키 입력)
- [ ] **Authentication → Providers → Anonymous sign-ins** 활성화
      (공유 링크 방문자/익명 코멘트에 필요)
- [ ] (선택) **Authentication → URL Configuration** 에 배포 도메인의 redirect URL 등록
