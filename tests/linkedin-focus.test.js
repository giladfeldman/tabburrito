// Offline test of LINKEDIN_FEED_FOCUS_JS with a minimal fake DOM.
// Usage: node tests/linkedin-focus.test.js [path-to-main.rs]  (run from the repo root)
const fs = require('fs');
const src = fs.readFileSync(process.argv[2] || require('path').join(__dirname, '..', 'src-tauri', 'src', 'main.rs'), 'utf8');
const m = src.match(/const LINKEDIN_FEED_FOCUS_JS: &str = r#"([\s\S]*?)"#;/);
if (!m) { console.log('FAIL: const not found'); process.exit(1); }
const JS = m[1];

const MENU = 'Open control menu for post by ';
function makePost({ author, heading = 'Feed post', context = [], follow = false, rendered = true }) {
  const attrs = {};
  const buttons = [{ getAttribute: () => MENU + author }];
  if (follow) buttons.push({ getAttribute: () => 'Follow ' + author });
  const p = {
    kind: 'post', author, heading, context, follow, rendered,
    get innerText() { return [this.heading, ...this.context, this.author, 'body text'].join('\n'); },
    getAttribute: k => (k in attrs ? attrs[k] : null),
    setAttribute: (k, v) => { attrs[k] = String(v); },
    removeAttribute: k => { delete attrs[k]; },
    hasAttr: k => k in attrs,
    closest: sel => (sel.includes('aside') || sel.includes('data-tb-hidden') ? null : p),
    getClientRects() { return (this.rendered && !('data-tb-why' in attrs)) ? [1] : []; },
    querySelector: () => ({ innerText: p.heading }),
    querySelectorAll: sel => (sel.startsWith('button[aria-label^=') ? buttons.slice(0, 1) : buttons),
  };
  p.menu = { getAttribute: () => MENU + p.author, closest: () => p };
  p.recycle = (a, opts) => { p.author = a; Object.assign(p, opts); buttons.length = 0;
    buttons.push({ getAttribute: () => MENU + a }); if (opts.follow) buttons.push({ getAttribute: () => 'Follow ' + a }); };
  return p;
}

function run(posts) {
  const doc = {
    getElementById: () => ({}), head: { appendChild() {} }, body: {},
    querySelectorAll(sel) {
      if (sel.startsWith('button[aria-label^=')) return posts.map(p => p.menu);
      if (sel === '[data-tb-focus][data-tb-why]') return posts.filter(p => p.hasAttr('data-tb-focus') && p.hasAttr('data-tb-why'));
      if (sel === '[data-tb-focus]') return posts.filter(p => p.hasAttr('data-tb-focus'));
      if (sel === '[data-tb-why]') return posts.filter(p => p.hasAttr('data-tb-why'));
      throw new Error('unhandled selector ' + sel);
    },
  };
  const win = {};
  const ctx = { window: win, document: doc, location: { pathname: '/feed/' },
    MutationObserver: class { observe() {} }, setTimeout: () => 0, clearTimeout() {}, setInterval: f => (win.__tick = f),
    console: { log() {}, warn: (...a) => (win.warned = a.join(' ')) } };
  new Function(...Object.keys(ctx), JS)(...Object.values(ctx));
  return win;
}

let fail = 0;
const ok = (name, cond) => { console.log((cond ? 'PASS ' : 'FAIL ') + name); if (!cond) fail++; };
const why = p => p.getAttribute('data-tb-why');

// 1. Classification of each kind.
{
  const posts = [
    makePost({ author: 'A Stranger', follow: true }),
    makePost({ author: 'B Followed', context: ['Followed by Carol Smith'], follow: true }),
    makePost({ author: 'C Contact' }),                                   // contact, no Follow button
    makePost({ author: 'D Liked', context: ['Dan Jones likes this'], follow: true }),
    makePost({ author: 'E Long', context: ['x'.repeat(200) + ' follows y'], follow: true }),
    makePost({ author: 'F Follows', context: ['Eve follows Frank'], follow: true }),
  ];
  run(posts);
  ok('stranger hidden', why(posts[0]) === 'stranger');
  ok('followed-by hidden', why(posts[1]) === 'followed-by');
  ok('contact kept', why(posts[2]) === null);
  ok('liked-by-contact kept', why(posts[3]) === null);
  ok('long context line with "follows" kept', why(posts[4]) === null);
  ok('"X follows Y" line hidden', why(posts[5]) === 'followed-by');
}
// 2. Breaker: 12 of 12 hidden -> trips, everything shown again.
{
  const posts = Array.from({ length: 12 }, (_, i) => makePost({ author: 'S' + i, follow: true }));
  const win = run(posts);
  ok('breaker trips at 12/12', win.__tbLiFocusStats().tripped === true && posts.every(p => why(p) === null));
  ok('breaker warns', /paused: 12 of 12/.test(win.warned || ''));
}
// 3. Breaker does not trip at the measured ~70%.
{
  const posts = [...Array.from({ length: 20 }, (_, i) => makePost({ author: 'S' + i, follow: true })),
                 ...Array.from({ length: 8 }, (_, i) => makePost({ author: 'K' + i }))];
  const win = run(posts);
  const st = win.__tbLiFocusStats();
  ok('no trip at 20/28 (71%)', st.tripped === false && st.stranger === 20 && st.checked === 28);
}
// 4. Breaker needs at least 10 checked posts.
{
  const posts = Array.from({ length: 9 }, (_, i) => makePost({ author: 'S' + i, follow: true }));
  const win = run(posts);
  ok('no trip below 10 checked', win.__tbLiFocusStats().tripped === false && posts.every(p => why(p) === 'stranger'));
}
// 5. Recycled element: hidden stranger reused for a contact gets re-read.
{
  const keep = Array.from({ length: 5 }, (_, i) => makePost({ author: 'K' + i }));
  const p = makePost({ author: 'Old Stranger', follow: true });
  const win = run([p, ...keep]);
  ok('recycle: first hidden', why(p) === 'stranger');
  p.recycle('New Contact', { follow: false, context: [] });
  win.__tick();
  ok('recycle: verdict cleared and re-read', why(p) === null && p.getAttribute('data-tb-focus') === 'New Contact');
}
// 6. Toggle off then on.
{
  const posts = [makePost({ author: 'S', follow: true }), makePost({ author: 'K' })];
  const win = run(posts);
  win.__tbSetLiFocus(false);
  ok('off shows everything', posts.every(p => why(p) === null));
  win.__tbSetLiFocus(true);
  ok('on hides again', why(posts[0]) === 'stranger');
}
console.log(fail ? `${fail} FAILED` : 'ALL PASS');
process.exit(fail ? 1 : 0);
