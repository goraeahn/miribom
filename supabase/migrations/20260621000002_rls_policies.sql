-- ============================================================================
-- 미리봄(Miribom) 백엔드 — 2) 접근 제어 규칙 (RLS 정책)
-- ----------------------------------------------------------------------------
-- 선언하는 규칙(요청 사항 그대로):
--   1) 작가는 자기 원고/대시보드만 본다.
--   2) 공유 토큰 보유자만 그 스냅샷을 본다.
--   3) 익명 코멘트 작성자는 자신이 연 그 스냅샷 하나에만 코멘트할 수 있다.
--
-- 접근 흐름(클라이언트):
--   - 공유 링크 방문자는 먼저 "익명 로그인"(supabase.auth.signInAnonymously)을 한다.
--     → 익명이라도 auth.uid() 가 생겨 RLS 로 깔끔하게 통제할 수 있다.
--   - 그 뒤 redeem_share(token) RPC 를 호출 → 토큰이 맞으면 스냅샷을 돌려주고
--     share_grants 에 (이 스냅샷, 이 사용자) 행을 기록한다.
--   - 이후 그 사용자는 "grant 가 있는 스냅샷"의 코멘트만 읽고/달 수 있다.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 토큰 교환 함수 : 비밀 토큰 검증은 RLS 만으로 안전하게 못 하므로(행 열거 위험)
--   SECURITY DEFINER 함수로 처리한다 — Supabase 표준 패턴.
-- ----------------------------------------------------------------------------
create or replace function public.redeem_share(p_token text)
returns public.shares
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.shares;
begin
  select *
    into s
    from public.shares
   where token = p_token
     and is_active
     and (expires_at is null or expires_at > now());

  if not found then
    raise exception 'invalid_or_expired_token' using errcode = 'no_data_found';
  end if;

  -- 로그인(익명 포함) 상태라면 열람 권한을 기록한다.
  -- 익명 로그인을 안 한 순수 anon 호출도 스냅샷 본문은 받을 수 있으나(토큰 보유자),
  -- 코멘트를 읽거나 달려면 grant 가 필요하므로 익명 로그인이 사실상 필수다.
  if auth.uid() is not null then
    insert into public.share_grants (share_id, user_id)
    values (s.id, auth.uid())
    on conflict do nothing;
  end if;

  return s;
end;
$$;

comment on function public.redeem_share(text) is
  '공유 토큰을 검증해 스냅샷을 반환하고, 호출자에게 열람 권한(share_grants)을 부여한다.';

-- ----------------------------------------------------------------------------
-- RLS 활성화 (기본은 모두 차단; 아래 정책으로만 열어 준다)
-- ----------------------------------------------------------------------------
alter table public.profiles     enable row level security;
alter table public.documents    enable row level security;
alter table public.shares       enable row level security;
alter table public.share_grants enable row level security;
alter table public.comments     enable row level security;

-- ============================================================================
-- profiles : 본인 프로필만
-- ============================================================================
create policy profiles_select_own on public.profiles
  for select using (auth.uid() = id);

create policy profiles_insert_own on public.profiles
  for insert with check (auth.uid() = id);

create policy profiles_update_own on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- ============================================================================
-- (규칙 1) documents : 작가는 자기 원고만 — 읽기/쓰기/수정/삭제 전부 본인만
-- ============================================================================
create policy documents_owner_all on public.documents
  for all using (auth.uid() = owner_id) with check (auth.uid() = owner_id);

-- ============================================================================
-- (규칙 2) shares : 소유자는 전권. 토큰 보유자(grant 보유)는 열람만.
-- ============================================================================
create policy shares_owner_all on public.shares
  for all using (auth.uid() = owner_id) with check (auth.uid() = owner_id);

create policy shares_select_granted on public.shares
  for select using (
    exists (
      select 1 from public.share_grants g
      where g.share_id = shares.id
        and g.user_id = auth.uid()
    )
  );

-- ============================================================================
-- share_grants : 본인이 받은 권한만 조회. (행 삽입은 redeem_share 가 담당)
-- ============================================================================
create policy grants_select_own on public.share_grants
  for select using (auth.uid() = user_id);

-- ============================================================================
-- (규칙 3) comments : 익명 코멘트 작성자는 '자신이 연 스냅샷 하나'에만
-- ----------------------------------------------------------------------------
--   - 읽기 : 그 스냅샷에 grant 가 있는 사람 (+ 그 스냅샷의 작가)
--   - 쓰기 : grant 가 있고, allow_comments/활성 상태이며, author_id = 본인
--   - 수정/삭제 : 본인 코멘트만 (작가는 자기 스냅샷 코멘트를 삭제(검열) 가능)
-- ============================================================================

-- 읽기: grant 보유자 (자신이 연 스냅샷의 코멘트 스레드)
create policy comments_select_granted on public.comments
  for select using (
    exists (
      select 1 from public.share_grants g
      where g.share_id = comments.share_id
        and g.user_id = auth.uid()
    )
  );

-- 읽기: 해당 스냅샷의 작가도 자기 글의 코멘트를 본다 (대시보드/검열용)
create policy comments_select_owner on public.comments
  for select using (
    exists (
      select 1 from public.shares s
      where s.id = comments.share_id
        and s.owner_id = auth.uid()
    )
  );

-- 쓰기: grant 가 있는 그 스냅샷에만, 본인 명의로, 코멘트가 허용된 활성 스냅샷에
create policy comments_insert_granted on public.comments
  for insert with check (
    author_id = auth.uid()
    and exists (
      select 1
        from public.share_grants g
        join public.shares s on s.id = g.share_id
       where g.share_id = comments.share_id
         and g.user_id = auth.uid()
         and s.allow_comments
         and s.is_active
    )
  );

-- 수정: 본인 코멘트만
create policy comments_update_own on public.comments
  for update using (author_id = auth.uid()) with check (author_id = auth.uid());

-- 삭제: 본인 코멘트 또는 그 스냅샷의 작가(검열)
create policy comments_delete_own_or_owner on public.comments
  for delete using (
    author_id = auth.uid()
    or exists (
      select 1 from public.shares s
      where s.id = comments.share_id
        and s.owner_id = auth.uid()
    )
  );

-- ============================================================================
-- (규칙 1) 작가 대시보드 : 자기 문서별 공유/코멘트 집계
--   security_invoker = true → 호출자의 RLS 로 평가되어 본인 문서만 보인다.
-- ============================================================================
create view public.author_dashboard
  with (security_invoker = true)
  as
select
  d.id                        as document_id,
  d.owner_id,
  d.title,
  d.updated_at,
  count(distinct sh.id)       as share_count,
  count(c.id)                 as comment_count,
  max(c.created_at)           as last_comment_at
from public.documents d
left join public.shares   sh on sh.document_id = d.id
left join public.comments c  on c.share_id = sh.id
group by d.id;

comment on view public.author_dashboard is '작가별 문서 대시보드(공유 수/코멘트 수). 호출자 RLS 로 본인 문서만 노출.';

-- ============================================================================
-- 역할(role) 권한 부여
--   anon          : 비로그인. 토큰 교환 RPC 만 실행 가능.
--   authenticated : 로그인(익명 로그인 포함). 실제 접근은 위 RLS 가 통제.
-- ============================================================================
grant usage on schema public to anon, authenticated;

grant select, insert, update, delete on public.documents    to authenticated;
grant select, insert, update, delete on public.shares       to authenticated;
grant select                          on public.share_grants to authenticated;
grant select, insert, update, delete on public.comments     to authenticated;
grant select, insert, update          on public.profiles     to authenticated;
grant select                          on public.author_dashboard to authenticated;

-- 토큰 교환 함수는 비로그인/로그인 모두 호출 가능
grant execute on function public.redeem_share(text) to anon, authenticated;
