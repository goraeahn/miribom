-- ============================================================================
-- 미리봄(Miribom) 백엔드 — 8) 공용 서재 공개본 (public_works)
-- ----------------------------------------------------------------------------
-- 목표(3차 기획서 ②):
--   작가가 "공개"로 고른 원고만 진열하는 큐레이션 서가. 공개 시점의 본문/표지를
--   동결 복사(공유와 동일 철학)하고 카테고리 1개로 분류한다. 비공개 원고는 절대
--   노출되지 않으며, 공개는 원고 소유자가 명시적으로 publish_work 를 호출할 때만 일어난다.
--
-- 결정 반영(2026-06-24, 고래):
--   - 작가 소개(profiles bio/link) 기능 전면 삭제 → 작가 정보 컬럼 없음.
--     (책 자체의 '저자'는 본문 YAML 안에 있어 그대로 표지/제목에 나옴.)
--   - 카테고리 6종: 일반소설 / 장르소설 / 시·시집 / 에세이·산문 / 동화 / 안내서·실용.
--
-- 설계 메모:
--   - 공개본은 공개 콘텐츠라 anon 이 직접 select 한다(공유와 달리 토큰/이름 게이트 없음).
--     RLS 로 is_active=true 행만 보이게 하고 anon 에 select 권한을 준다.
--   - 공개/갱신은 SECURITY DEFINER 함수 publish_work(소유 확인 + 카테고리 검증 + 동결 복사).
--     회수/삭제는 소유자 RLS 로 클라이언트가 직접 update(is_active=false)/delete.
--   - 원본 documents 행이 지워지면 on delete cascade 로 공개본도 사라진다.
--
-- 적용: Supabase 대시보드 → SQL Editor 에 이 파일 내용을 붙여넣고 실행.
--       (재실행 안전: create table if not exists / create or replace / drop policy if exists)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) public_works 테이블 — 공개 시점 동결 복사본 (document 당 1행)
-- ----------------------------------------------------------------------------
create table if not exists public.public_works (
  id          uuid primary key default gen_random_uuid(),
  document_id uuid not null unique references public.documents (id) on delete cascade,
  owner_id    uuid not null references auth.users (id)  on delete cascade,
  slug        text not null unique,
  title       text not null,
  content_md  text not null,
  cover_path  text,
  category    text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.public_works is
  '공용 서재 공개본. 공개 시점의 제목/본문/표지를 동결 복사. document 당 1행(document_id unique). 원본 삭제 시 cascade.';
comment on column public.public_works.slug is
  '공개 URL용(?work=slug). 공개 콘텐츠라 추측 가능해도 무방.';
comment on column public.public_works.category is
  '분류 1개: 일반소설 | 장르소설 | 시·시집 | 에세이·산문 | 동화 | 안내서·실용.';

create index if not exists public_works_active_idx   on public.public_works (is_active);
create index if not exists public_works_category_idx on public.public_works (category);
create index if not exists public_works_owner_idx    on public.public_works (owner_id);

-- ----------------------------------------------------------------------------
-- 2) RLS — 누구나 활성 공개본 read / 소유자만 본인 행 전권(회수·삭제 포함)
-- ----------------------------------------------------------------------------
alter table public.public_works enable row level security;

drop policy if exists public_works_anon_select on public.public_works;
create policy public_works_anon_select on public.public_works
  for select using (is_active = true);

drop policy if exists public_works_owner_all on public.public_works;
create policy public_works_owner_all on public.public_works
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- 권한: 비로그인은 공개본을 직접 읽기만. 로그인 소유자는 본인 행 회수/삭제(update/delete).
-- 공개(insert)는 grant 하지 않는다 → 반드시 publish_work RPC(소유·카테고리 검증)로만.
grant select                  on public.public_works to anon;
grant select, update, delete  on public.public_works to authenticated;

-- ----------------------------------------------------------------------------
-- 3) publish_work : 원고를 공용 서재에 공개(또는 갱신)
--    - 호출자가 그 원고 소유자인지 확인
--    - 카테고리 검증(허용 6종)
--    - 제목/본문/표지를 그 순간 그대로 동결 복사
--    - 같은 원고가 이미 공개돼 있으면 슬러그 유지한 채 내용만 다시 굳힘("공개본 갱신")
-- ----------------------------------------------------------------------------
create or replace function public.publish_work(
  p_document_id uuid,
  p_category    text,
  p_slug        text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  d      public.documents;
  v_cat  text;
  v_base text;
  w      public.public_works;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;

  select * into d from public.documents where id = p_document_id;
  if not found or d.owner_id <> auth.uid() then
    raise exception 'document_not_found_or_forbidden' using errcode = 'insufficient_privilege';
  end if;

  v_cat := case p_category
      when '일반소설'    then '일반소설'
      when '장르소설'    then '장르소설'
      when '시·시집'     then '시·시집'
      when '에세이·산문' then '에세이·산문'
      when '동화'        then '동화'
      when '안내서·실용' then '안내서·실용'
      else null
    end;
  if v_cat is null then
    raise exception 'invalid_category' using errcode = 'check_violation';
  end if;

  -- 이미 공개된 원고면 슬러그는 그대로 두고 내용만 다시 동결(갱신)
  select * into w from public.public_works where document_id = d.id;
  if found then
    update public.public_works
       set title = d.title, content_md = d.content_md, cover_path = d.cover_path,
           category = v_cat, is_active = true, updated_at = now()
     where id = w.id
     returning * into w;
    return json_build_object('work_id', w.id, 'slug', w.slug,
      'category', w.category, 'is_active', w.is_active, 'updated', true);
  end if;

  -- 새 공개: 슬러그 base(전달값 또는 제목) 정규화 → 임의 접미사로 유일 보장
  v_base := nullif(btrim(coalesce(p_slug, '')), '');
  if v_base is null then v_base := d.title; end if;
  v_base := btrim(regexp_replace(lower(coalesce(v_base, '')), '[^a-z0-9가-힣]+', '-', 'g'), '-');
  if v_base = '' then v_base := 'work'; end if;
  v_base := left(v_base, 40);

  loop
    begin
      insert into public.public_works
        (document_id, owner_id, slug, title, content_md, cover_path, category, is_active)
      values
        (d.id, d.owner_id,
         v_base || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 6),
         d.title, d.content_md, d.cover_path, v_cat, true)
      returning * into w;
      exit;
    exception when unique_violation then
      null;  -- 슬러그가 우연히 겹치면 새 접미사로 재시도
    end;
  end loop;

  return json_build_object('work_id', w.id, 'slug', w.slug,
    'category', w.category, 'is_active', w.is_active, 'updated', false);
end;
$$;

comment on function public.publish_work(uuid, text, text) is
  '원고 소유자가 원고를 공용 서재에 공개/갱신한다. 제목·본문·표지를 동결 복사하고 카테고리(6종)를 검증한다.';

-- ----------------------------------------------------------------------------
-- 4) 실행 권한 — 공개/갱신은 로그인 사용자만(소유는 함수 안에서 확인).
--    회수/삭제는 위 2)의 소유자 RLS 로 클라이언트가 직접.
-- ----------------------------------------------------------------------------
grant execute on function public.publish_work(uuid, text, text) to authenticated;

-- 확인용(선택):
--   select slug, category, is_active, created_at from public.public_works order by created_at desc limit 10;
