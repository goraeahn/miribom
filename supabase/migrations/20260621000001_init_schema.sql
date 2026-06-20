-- ============================================================================
-- 미리봄(Miribom) 백엔드 — 1) 스키마 정의
-- ----------------------------------------------------------------------------
-- 이 파일은 git 에 커밋되는 "재현 가능한" 마이그레이션입니다.
-- 대시보드에서 손으로 표를 만들지 말고, 아래 명령으로 동일하게 적용하세요.
--
--   # 원격(클라우드) 프로젝트에 적용
--   supabase db push
--
--   # 또는 DB URL 로 직접 적용 (회사 서버/셀프호스팅 재현)
--   psql "$SUPABASE_DB_URL" -f supabase/migrations/20260621000001_init_schema.sql
--
-- 데이터 모델 한 줄 요약
--   profiles  : 작가(= auth.users 와 1:1)
--   documents : 작업 원고. "원본 마크다운"을 그대로 저장(렌더된 HTML 아님).
--   shares    : 공유 스냅샷. 공유 시점의 마크다운을 동결 복사 + 고유 토큰.
--   grants    : 토큰을 제시해 스냅샷을 연 (익명 포함) 사용자 기록.
--   comments  : 스냅샷에 달리는 (익명) 코멘트.
-- ============================================================================

-- 토큰 생성을 위한 pgcrypto (gen_random_bytes). uuid 는 PG 코어 gen_random_uuid 사용.
create extension if not exists pgcrypto with schema extensions;

-- ----------------------------------------------------------------------------
-- 공통: updated_at 자동 갱신 트리거 함수
-- ----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- profiles : 작가 프로필 (auth.users 와 1:1)
-- ----------------------------------------------------------------------------
create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

comment on table public.profiles is '작가 프로필. auth.users 와 1:1.';

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- 가입(또는 익명 로그인이 아닌 실제 가입) 시 프로필 자동 생성
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 익명 로그인 사용자(공유링크 방문자)는 프로필을 만들지 않음
  if coalesce(new.is_anonymous, false) then
    return new;
  end if;

  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'name',
      new.raw_user_meta_data ->> 'full_name',
      nullif(split_part(coalesce(new.email, ''), '@', 1), '')
    )
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ----------------------------------------------------------------------------
-- documents : 작업 원고 (원본 마크다운 저장)
-- ----------------------------------------------------------------------------
create table public.documents (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references auth.users (id) on delete cascade,
  title      text not null default '제목 없음',
  -- 중요: 렌더된 HTML 이 아니라 "원본 마크다운"을 그대로 저장한다.
  --       화면 표시는 기존 미리봄 파서(assemble)가 클라이언트에서 담당한다.
  content_md text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column public.documents.content_md is '원본 마크다운 원문. 렌더된 HTML 을 저장하지 않는다.';

create index documents_owner_id_idx on public.documents (owner_id);

create trigger documents_set_updated_at
  before update on public.documents
  for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------------------
-- shares : 공유 스냅샷 (공유 시점 마크다운을 동결 + 고유 토큰)
-- ----------------------------------------------------------------------------
create table public.shares (
  id             uuid primary key default gen_random_uuid(),
  document_id    uuid not null references public.documents (id) on delete cascade,
  owner_id       uuid not null references auth.users (id) on delete cascade,
  -- 공유 URL 에 쓰이는 추측 불가 토큰 (48 hex chars)
  token          text not null unique default encode(extensions.gen_random_bytes(24), 'hex'),
  title          text not null default '',
  -- 공유한 순간의 원본 마크다운을 그대로 동결 저장(원고를 더 고쳐도 스냅샷은 불변).
  content_md     text not null,
  allow_comments boolean not null default true,
  is_active      boolean not null default true,
  expires_at     timestamptz,
  created_at     timestamptz not null default now()
);

comment on table public.shares is '문서의 공유 스냅샷. 공유 시점의 원본 마크다운을 동결 저장한다.';
comment on column public.shares.token is '공유 링크용 추측 불가 토큰. 이 값을 아는 것이 곧 열람 권한.';

create index shares_document_id_idx on public.shares (document_id);
create index shares_owner_id_idx    on public.shares (owner_id);

-- ----------------------------------------------------------------------------
-- share_grants : 토큰을 제시해 스냅샷을 '연' (익명 포함) 사용자 기록
--   - redeem_share() 함수(다음 마이그레이션)가 토큰 검증 후 여기에 행을 넣는다.
--   - RLS 가 "이 사용자가 이 스냅샷에 대한 grant 를 갖고 있는가"로 접근을 판정한다.
-- ----------------------------------------------------------------------------
create table public.share_grants (
  share_id   uuid not null references public.shares (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  granted_at timestamptz not null default now(),
  primary key (share_id, user_id)
);

comment on table public.share_grants is '토큰을 제시해 스냅샷을 연 사용자(익명 포함) 기록. RLS 판정의 열쇠.';

-- ----------------------------------------------------------------------------
-- comments : 스냅샷에 달리는 (익명) 코멘트
-- ----------------------------------------------------------------------------
create table public.comments (
  id          uuid primary key default gen_random_uuid(),
  share_id    uuid not null references public.shares (id) on delete cascade,
  -- 익명 로그인 사용자의 uid (계정 삭제 시 코멘트는 남기고 작성자만 비움)
  author_id   uuid references auth.users (id) on delete set null,
  author_name text not null default '익명',
  body        text not null,
  -- 원고 내 위치(선택): 문단 id/오프셋 등. 인라인 코멘트 확장용.
  anchor      text,
  created_at  timestamptz not null default now()
);

comment on table public.comments is '공유 스냅샷에 달리는 익명 코멘트.';

create index comments_share_id_idx on public.comments (share_id);
