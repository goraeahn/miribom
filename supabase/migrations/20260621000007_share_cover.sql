-- 미리봄 v2 D2 — 공유 스냅샷에 표지(cover_path) 포함
-- 공유 생성 시 표지 경로를 동결 복사하고, share_enter가 함께 반환한다.
-- (표지 이미지는 covers 공개 버킷이라 비로그인 방문자도 공개 URL로 표시 가능)

alter table public.shares
  add column if not exists cover_path text;

comment on column public.shares.cover_path is
  '공유 시점의 표지 Storage 경로(covers 버킷). 공개 URL로 표시. 없으면 자동 표지.';

-- ----------------------------------------------------------------------------
-- create_share_link : 표지 경로도 동결 복사 (기존과 동일 + cover_path 추가)
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

  insert into public.shares (document_id, owner_id, title, content_md, cover_path, period, expires_at, is_active)
  values (d.id, d.owner_id, d.title, d.content_md, d.cover_path, v_period, v_expires, true)
  returning * into s;

  return json_build_object(
    'share_id',   s.id,
    'token',      s.token,
    'period',     s.period,
    'expires_at', s.expires_at
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- share_enter : 표지 경로도 함께 반환 (기존과 동일 + cover_path 추가)
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
    'content_md', s.content_md,
    'cover_path', s.cover_path
  );
end;
$$;

-- 권한 재확인(create or replace는 grant 유지하지만 명시)
grant execute on function public.create_share_link(uuid, text) to authenticated;
grant execute on function public.share_enter(text, text)       to anon, authenticated;

-- 확인용(선택): select cover_path from public.shares limit 5;
