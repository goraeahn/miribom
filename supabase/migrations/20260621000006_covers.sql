-- 미리봄 v2 — 표지(cover) 기반
-- documents 표지 경로 컬럼 + covers Storage 버킷 + RLS
--
-- 결정(가볍게): 표지 "이미지"는 공개 읽기 버킷 + 작성자만 쓰기/삭제.
--   원고 텍스트(content_md)는 기존대로 비공개(documents RLS). 표지 경로 컬럼도 소유자만 조회.
--   공유 시에는 share_enter RPC가 cover_path를 함께 내려보낼 예정(다음 단계 D).
--
-- 경로 규칙: covers/{owner_uid}/{document_id}/display.<ext>  (표시용 ~1600px)
--            covers/{owner_uid}/{document_id}/thumb.<ext>    (그리드용 ~500px)

-- ───────────────────────────────────────────────────────────
-- 1) documents 표지 경로 컬럼
-- ───────────────────────────────────────────────────────────
alter table public.documents
  add column if not exists cover_path       text,
  add column if not exists cover_thumb_path text;

-- ───────────────────────────────────────────────────────────
-- 2) covers 버킷 (공개 읽기 · 2MB · jpg/png/webp)
-- ───────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('covers', 'covers', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public            = excluded.public,
      file_size_limit   = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ───────────────────────────────────────────────────────────
-- 3) Storage RLS (storage.objects) — covers 버킷 한정
--    읽기=공개 / 쓰기·수정·삭제=본인 폴더(첫 경로 = 내 uid)
-- ───────────────────────────────────────────────────────────

-- 공개 읽기 (공유 링크·뷰어에서 표지 표시)
drop policy if exists "covers_public_read" on storage.objects;
create policy "covers_public_read" on storage.objects
  for select to public
  using ( bucket_id = 'covers' );

-- 업로드: 본인 폴더에만
drop policy if exists "covers_owner_insert" on storage.objects;
create policy "covers_owner_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'covers'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 교체(덮어쓰기): 본인 폴더만
drop policy if exists "covers_owner_update" on storage.objects;
create policy "covers_owner_update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'covers'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'covers'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 삭제: 본인 폴더만 (원고 삭제 시 표지 정리에 사용)
drop policy if exists "covers_owner_delete" on storage.objects;
create policy "covers_owner_delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'covers'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ───────────────────────────────────────────────────────────
-- 확인용(선택): 적용 후 아래를 실행해 보면 됨
-- ───────────────────────────────────────────────────────────
-- select column_name from information_schema.columns
--   where table_name='documents' and column_name like 'cover%';
-- select id, public, file_size_limit, allowed_mime_types
--   from storage.buckets where id='covers';
-- 가벼운 격리 확인: 다른 계정으로 로그인해 남의 uid 폴더에 업로드 시도 → 거부되면 정상.
