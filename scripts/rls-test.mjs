// 미리봄 RLS 격리 자동 테스트 (P0: 현행 정책)
// "비공개 원고는 절대 새지 않는다"를 익명 세션 2개로 증명한다.
//
// 실행:  cd scripts && npm install && node rls-test.mjs
// 키 출처: 루트 config.js (anon/publishable 키 — DDL 불가, 데이터 평면만)
//
// 부수효과: 사장님 Supabase에 익명 테스트 세션 2개 + 테스트 원고 1건을 만들었다
//          끝에 삭제한다. 실데이터(내 서재)는 건드리지 않는다.

import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';

// ── 설정 읽기 (config.js 에서 URL/anon 키 추출) ─────────────────
const cfg = readFileSync(new URL('../config.js', import.meta.url), 'utf8');
const URL_ = cfg.match(/SUPABASE_URL\s*:\s*["']([^"']+)["']/)?.[1];
const ANON = cfg.match(/SUPABASE_ANON_KEY\s*:\s*["']([^"']+)["']/)?.[1];
if (!URL_ || !ANON) { console.error('❌ config.js에서 URL/anon 키를 못 읽음'); process.exit(1); }

const mkClient = () => createClient(URL_, ANON, {
  auth: { persistSession: false, autoRefreshToken: false },
});

let pass = 0, fail = 0;
const check = (name, cond) => { cond ? pass++ : fail++; console.log(`  ${cond ? '✅' : '❌ FAIL'}  ${name}`); };

async function anonSession(label) {
  const c = mkClient();
  const { data, error } = await c.auth.signInAnonymously();
  if (error || !data?.user) {
    throw new Error(`${label} 익명 로그인 실패: ${error?.message || '세션 없음'}\n` +
      '→ Supabase 대시보드 Authentication > Sign In/Providers 에서 "Anonymous sign-ins"가 켜져 있어야 합니다.');
  }
  return { c, uid: data.user.id };
}

async function main() {
  console.log('미리봄 RLS 격리 테스트 —', URL_, '\n');

  console.log('· 익명 세션 2개 생성(A, B) + 비로그인 클라이언트');
  const A = await anonSession('A');
  const B = await anonSession('B');
  const anon = mkClient(); // 로그인하지 않은 anon 키 클라이언트

  // A가 비공개 원고 작성
  const { data: docA, error: insErr } = await A.c.from('documents')
    .insert({ owner_id: A.uid, title: 'RLS-TEST-A', content_md: 'SECRET-A' })
    .select().single();
  console.log('\n[documents 격리]');
  check('A가 자기 원고를 만든다(양성 대조)', !insErr && !!docA);
  if (insErr) { console.error('   insert 오류:', insErr.message); }

  if (docA) {
    const { data: aRead } = await A.c.from('documents').select().eq('id', docA.id);
    check('A는 자기 원고를 읽는다(양성 대조)', aRead?.length === 1);

    const { data: bRead } = await B.c.from('documents').select().eq('id', docA.id);
    check('B는 A의 비공개 원고를 못 읽는다', (bRead?.length || 0) === 0);

    const { data: anonRead } = await anon.from('documents').select().eq('id', docA.id);
    check('비로그인 방문자는 A의 비공개 원고를 못 읽는다', (anonRead?.length || 0) === 0);

    const { data: bUpd } = await B.c.from('documents')
      .update({ content_md: 'HACKED-BY-B' }).eq('id', docA.id).select();
    check('B는 A의 원고를 수정하지 못한다(0행)', (bUpd?.length || 0) === 0);

    const { data: still } = await A.c.from('documents')
      .select('content_md').eq('id', docA.id).single();
    check('변조 시도 후에도 A 원고 내용은 그대로', still?.content_md === 'SECRET-A');

    // ── 공유 접속로그 격리 (③ 회귀) ─────────────────────────────
    console.log('\n[share_access_events 격리]');
    const { data: link, error: linkErr } = await A.c.rpc('create_share_link', {
      p_document_id: docA.id, p_period: '1w',
    });
    check('A가 공유 링크를 만든다(양성 대조)', !linkErr && !!link?.share_id);
    if (link?.share_id) {
      const { data: bEvents } = await B.c.from('share_access_events')
        .select().eq('share_id', link.share_id);
      check('B는 남의 공유 접속로그를 못 읽는다', (bEvents?.length || 0) === 0);

      const { data: aEvents, error: aEvErr } = await A.c.from('share_access_events')
        .select().eq('share_id', link.share_id);
      check('A는 자기 공유 접속로그를 읽을 수 있다(양성 대조)', !aEvErr && Array.isArray(aEvents));
    }

    // 정리
    await A.c.from('documents').delete().eq('id', docA.id);
    console.log('\n🧹 테스트 원고 삭제(공유는 cascade로 함께 정리)');
  }

  console.log(`\n━━━ 결과: ${pass} PASS / ${fail} FAIL ━━━`);
  if (fail) { console.error('⚠️  격리가 깨진 항목이 있습니다. 공개/공유 기능 진행 전 반드시 수정하세요.'); }
  else { console.log('🔒 현행 RLS 격리 정상 — 비공개 원고는 새지 않습니다.'); }
  process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error('\n❌ 테스트 중단:', e.message); process.exit(2); });
