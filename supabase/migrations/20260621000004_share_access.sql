-- ============================================================================
-- 미리봄(Miribom) 백엔드 — 4) 비공개 공유 링크 + 접속 로그
-- ----------------------------------------------------------------------------
-- 목표(기획서):
--   작성자가 원고마다 고유 URL 을 만들고, 받는 사람은 "이름만" 입력하면
--   읽기 전용으로 본다. 링크는 설정 기간(기본 한 달) 뒤 자동으로 닫히고,
--   "누가 언제 들어왔는지"(이름 + 시각)를 작성자에게 기록한다.
--
-- 설계 메모:
--   - 기존 shares 테이블을 재사용한다. shares.content_md 는 "공유 시점의 원고"를
--     동결 저장하므로(원고를 더 고쳐도 링크는 불변), 기획 결정 "내용 고정"과 일치.
--   - 이름 입력은 인증이 아니라 "식별"이다. 비밀 토큰을 아는 것이 곧 열람 권한이며,
--     RLS 만으로 토큰 검증을 하면 행 열거 위험이 있으므로 SECURITY DEFINER 함수로 처리
--     (기존 redeem_share 와 동일한 표준 패턴).
--   - 뷰어는 로그인하지 않는다. anon 역할이 RPC 만 실행해 본문을 받는다.
--
-- 적용:
--   supabase db push
--   또는 Supabase 대시보드 → SQL Editor 에 이 파일 내용을 붙여넣고 실행.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) shares 에 공개 기간(표시용) 컬럼 추가
--    만료 "시각"은 기존 expires_at 컬럼을 그대로 쓰고, period 는 화면 표시·재계산용.
-- ----------------------------------------------------------------------------
alter table public.shares
  add column if not exists period text;

comment on column public.shares.period is
  '공개 기간 표시값: 1w | 2w | 1m | 3m. 실제 만료 시각은 expires_at.';

-- ----------------------------------------------------------------------------
-- 2) share_access_events : 접속 로그 (이름 + 시각이 핵심, ip/ua 는 보조)
--    - share 가 지워지면(원고 삭제 cascade 포함) 로그도 함께 정리(on delete cascade).
-- ----------------------------------------------------------------------------
create table if not exists public.share_access_events (
  id          uuid primary key default gen_random_uuid(),
  share_id    uuid not null references public.shares (id) on delete cascade,
  viewer_name text not null,
  ip          text,
  user_agent  text,
  occurred_at timestamptz not null default now()
);

comment on table public.share_access_events is
  '공유 링크 접속 로그. 이름 입력(=읽기 시작) 시점마다 1건. 재방문도 새 행으로 누적.';

create index if not exists share_access_events_share_id_idx
  on public.share_access_events (share_id);

alter table public.share_access_events enable row level security;

-- 작성자(해당 share 의 소유자)만 자신의 링크 접속 로그를 읽는다.
-- (익명 방문자는 직접 INSERT/SELECT 불가 — 기록은 아래 share_enter 함수가 담당)
drop policy if exists access_events_select_owner on public.share_access_events;
create policy access_events_select_owner on public.share_access_events
  for select using (
    exists (
      select 1 from public.shares s
      where s.id = share_access_events.share_id
        and s.owner_id = auth.uid()
    )
  );

-- ----------------------------------------------------------------------------
-- 3) create_share_link : 작성자가 원고로부터 공유 링크를 만든다
--    - 호출자가 그 원고의 소유자인지 확인
--    - 제목/본문을 "그 순간 그대로" 동결 복사
--    - period 로 expires_at 계산 (기본 한 달)
--    - 토큰은 shares.token 기본값(추측 불가 난수)이 자동 생성
-- ----------------------------------------------------------------------------
create or replace function public.create_share_link(
  p_document_id uuid,
  p_period      text default '1m'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  d         public.documents;
  v_period  text;
  v_expires timestamptz;
  s         public.shares;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;

  select * into d from public.documents where id = p_document_id;
  if not found or d.owner_id <> auth.uid() then
    raise exception 'document_not_found_or_forbidden' using errcode = 'insufficient_privilege';
  end if;

  v_period := case p_period when '1w' then '1w' when '2w' then '2w' when '3m' then '3m' else '1m' end;
  v_expires := now() + case v_period
      when '1w' then interval '7 days'
      when '2w' then interval '14 days'
      when '3m' then interval '3 months'
      else            interval '1 month'
    end;

  insert into public.shares (document_id, owner_id, title, content_md, period, expires_at, is_active)
  values (d.id, d.owner_id, d.title, d.content_md, v_period, v_expires, true)
  returning * into s;

  return json_build_object(
    'share_id',   s.id,
    'token',      s.token,
    'period',     s.period,
    'expires_at', s.expires_at
  );
end;
$$;

comment on function public.create_share_link(uuid, text) is
  '원고 소유자가 공유 링크를 생성한다. 제목/본문을 동결 복사하고 period 로 만료 시각을 정한다.';

-- ----------------------------------------------------------------------------
-- 4) share_status : 토큰 유효성만 판정 (본문 미반환)
--    - 이름 입력 화면을 보일지 / 만료 화면을 보일지 분기용.
--    - 존재하지 않는 토큰도 만료와 동일하게 ok=false (존재 여부 비노출).
-- ----------------------------------------------------------------------------
create or replace function public.share_status(p_token text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ok boolean;
begin
  select true into v_ok
    from public.shares
   where token = p_token
     and is_active
     and (expires_at is null or expires_at > now())
   limit 1;

  return json_build_object('ok', coalesce(v_ok, false));
end;
$$;

comment on function public.share_status(text) is
  '공유 토큰이 현재 유효한지(활성·미만료)만 반환. 본문은 주지 않는다.';

-- ----------------------------------------------------------------------------
-- 5) share_enter : 이름 기록 후 본문 반환 (= "읽기 시작")
--    - 빈 이름 거부
--    - 재검증 → 접속 로그 1건 기록(이름 + 시각 + 베스트에포트 ip/ua) → 제목/본문 반환
--    - 무효/만료면 ok=false (본문 미반환)
-- ----------------------------------------------------------------------------
create or replace function public.share_enter(
  p_token       text,
  p_viewer_name text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  s      public.shares;
  v_name text;
  hdrs   json;
  v_ip   text;
  v_ua   text;
begin
  v_name := nullif(btrim(coalesce(p_viewer_name, '')), '');
  if v_name is null then
    raise exception 'name_required' using errcode = 'check_violation';
  end if;

  select * into s
    from public.shares
   where token = p_token
     and is_active
     and (expires_at is null or expires_at > now());

  if not found then
    return json_build_object('ok', false);
  end if;

  -- 보조 기록(ip/ua): PostgREST 가 노출하는 요청 헤더에서 베스트에포트로 읽는다.
  begin
    hdrs := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    hdrs := null;
  end;
  if hdrs is not null then
    v_ip := split_part(coalesce(hdrs ->> 'x-forwarded-for', hdrs ->> 'x-real-ip', ''), ',', 1);
    v_ua := hdrs ->> 'user-agent';
  end if;

  insert into public.share_access_events (share_id, viewer_name, ip, user_agent)
  values (s.id, left(v_name, 120), nullif(btrim(coalesce(v_ip, '')), ''), v_ua);

  return json_build_object(
    'ok',         true,
    'title',      s.title,
    'content_md', s.content_md
  );
end;
$$;

comment on function public.share_enter(text, text) is
  '이름을 기록하고 공유 스냅샷 본문을 반환한다(= 읽기 시작). 매 호출이 접속 로그 1건.';

-- ----------------------------------------------------------------------------
-- 6) 실행 권한
--    - 생성은 로그인 사용자만.
--    - 상태확인/입장은 비로그인(anon) 방문자도 호출 가능(뷰어는 로그인하지 않음).
-- ----------------------------------------------------------------------------
grant select on public.share_access_events to authenticated;

grant execute on function public.create_share_link(uuid, text) to authenticated;
grant execute on function public.share_status(text)            to anon, authenticated;
grant execute on function public.share_enter(text, text)       to anon, authenticated;
