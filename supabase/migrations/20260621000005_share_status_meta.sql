-- ============================================================================
-- 미리봄(Miribom) 백엔드 — 5) 공유 진입 화면 안내용 메타데이터
-- ----------------------------------------------------------------------------
-- 이름 입력 화면에 "누가 / 무엇을 / 언제까지" 공유했는지 보여주기 위해,
-- share_status 가 본문은 빼고 메타데이터(공유자 이메일·제목·기간·만료시각)만
-- 함께 반환하도록 확장한다. 본문(content_md)은 여전히 이름 입력 후 share_enter 로만.
--
-- 적용: Supabase 대시보드 → SQL Editor 에 붙여넣고 Run (여러 번 실행해도 안전).
-- ============================================================================

create or replace function public.share_status(p_token text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  s       public.shares;
  v_email text;
begin
  select * into s
    from public.shares
   where token = p_token
     and is_active
     and (expires_at is null or expires_at > now());

  if not found then
    return json_build_object('ok', false);
  end if;

  -- 공유자(작성자) 이메일 — SECURITY DEFINER 이므로 auth.users 조회 가능.
  select email into v_email from auth.users where id = s.owner_id;

  return json_build_object(
    'ok',         true,
    'title',      s.title,
    'sharer',     v_email,
    'period',     s.period,
    'expires_at', s.expires_at
  );
end;
$$;

comment on function public.share_status(text) is
  '공유 토큰 유효성 + 진입 화면 안내용 메타데이터(공유자/제목/기간)를 반환. 본문은 주지 않는다.';

grant execute on function public.share_status(text) to anon, authenticated;
