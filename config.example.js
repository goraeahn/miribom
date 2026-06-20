// ============================================================================
// 미리봄(Miribom) 프런트엔드 설정 예시
// ----------------------------------------------------------------------------
// 미리봄은 빌드 과정이 없는 단일 HTML 이라 런타임에 .env 를 직접 읽지 못한다.
// 그래서 이 파일을 config.js 로 복사해 값을 채우고, index.html 에서
//   <script src="config.js"></script>
// 로 불러와 window.MIRIBOM_CONFIG 를 사용한다.
//
// 사용법:
//   1) cp config.example.js config.js
//   2) 아래 값을 .env 의 값과 동일하게 채운다.
//   3) config.js 는 커밋하지 않는다 (.gitignore 에 등록됨). 이 예시 파일만 커밋.
//
// 주의: 여기에는 공개해도 안전한 anon key 만 넣는다. service_role 키는 절대 금지.
// ============================================================================
window.MIRIBOM_CONFIG = {
  SUPABASE_URL: "",      // .env 의 SUPABASE_URL 과 동일
  SUPABASE_ANON_KEY: "", // .env 의 SUPABASE_ANON_KEY 와 동일(공개 가능)
};
