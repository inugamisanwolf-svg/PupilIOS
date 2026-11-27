/**
 * PupilIOS — the real Astryx surfaces, rendered offline inside WKWebView.
 *
 * Everything here is genuine Astryx React: the neutral theme provider, Card,
 * Stack/VStack/HStack, Heading/Text, Badge, Button, Switch and Divider from
 * @astryxdesign/core, wrapped in <Theme theme={neutralTheme} mode="dark">.
 *
 * Surfaces
 *   ?surface=settings  — 設定 (mirrors the SwiftUI settings that matter most)
 *   ?surface=about     — このアプリについて (GPLv3 / 移植元 / Astryx MIT)
 *
 * Bridge (contract §1)
 *   JS -> Swift : window.webkit.messageHandlers.pupil.postMessage({name, payload})
 *   Swift -> JS : window.pupilUpdate(jsonString)      // settings merge
 *                 window.PupilAstryx.mount('settings' | 'about')
 *
 * payload values are strings (Swift side is [String: String]); booleans arrive
 * as "true"/"false".
 */

import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';

import { Theme } from '@astryxdesign/core/theme';
import { neutralTheme } from '@astryxdesign/theme-neutral/built';
import { Card } from '@astryxdesign/core/Card';
import { Stack, HStack, VStack } from '@astryxdesign/core/Stack';
import { Text, Heading } from '@astryxdesign/core/Text';
import { Badge } from '@astryxdesign/core/Badge';
import { Button } from '@astryxdesign/core/Button';
import { Switch } from '@astryxdesign/core/Switch';
import { Divider } from '@astryxdesign/core/Divider';

/* -------------------------------------------------------------------------- */
/* versions (injected by design/build.mjs)                                     */
/* -------------------------------------------------------------------------- */

const ASTRYX_CORE = typeof __ASTRYX_CORE__ !== 'undefined' ? __ASTRYX_CORE__ : '0.7.17';
const ASTRYX_THEME = typeof __ASTRYX_THEME__ !== 'undefined' ? __ASTRYX_THEME__ : '0.7.17';
const REACT_VERSION = typeof __REACT_VERSION__ !== 'undefined' ? __REACT_VERSION__ : React.version;
const STYLEX_VERSION = typeof __STYLEX_VERSION__ !== 'undefined' ? __STYLEX_VERSION__ : '0.19';

const SOURCE_REPO = 'https://codeberg.org/pupil/Pupil';
const ASTRYX_REPO = 'https://github.com/meta/astryx';

/* -------------------------------------------------------------------------- */
/* bridge                                                                      */
/* -------------------------------------------------------------------------- */

function post(name, payload) {
  const bridge =
    typeof window !== 'undefined' &&
    window.webkit &&
    window.webkit.messageHandlers &&
    window.webkit.messageHandlers.pupil;
  const body = { name: String(name), payload: payload || {} };
  if (bridge && typeof bridge.postMessage === 'function') {
    try {
      bridge.postMessage(body);
      return;
    } catch (err) {
      /* fall through to the desktop log below */
    }
  }
  // Desktop preview (no native bridge): keep events observable in devtools.
  if (typeof console !== 'undefined') console.log('[pupil]', body.name, body.payload);
}

/* -------------------------------------------------------------------------- */
/* live theme bridge                                                           */
/* -------------------------------------------------------------------------- */

/*
 * Swift pushes the app's custom theme as `theme*` hex keys. They are written to
 * OUR css custom properties on <html>; design/src/pupil.css bridges
 *   --color-accent: var(--pupil-accent, #f1f1f1)
 * so every Astryx token (and therefore every Astryx component) follows without
 * re-rendering anything in React. Keys are frozen — see docs/ASTRYX.md §7.8.
 */

const THEME_VAR_MAP = {
  themeAccent: '--pupil-accent',
  themeOnAccent: '--pupil-on-accent',
  themeBackground: '--pupil-background',
  themeSurface: '--pupil-surface',
  themeSurfaceRaised: '--pupil-surface-raised',
  themeTextPrimary: '--pupil-text-primary',
  themeTextSecondary: '--pupil-text-secondary',
  themeBorder: '--pupil-border',
  themeDanger: '--pupil-danger',
};

const HEX_RE = /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/;

function normalizeHex(value) {
  if (typeof value !== 'string') return null;
  const text = value.trim();
  if (!HEX_RE.test(text)) return null;
  if (text.length === 4) {
    return ('#' + text[1] + text[1] + text[2] + text[2] + text[3] + text[3]).toUpperCase();
  }
  return text.toUpperCase();
}

function applyThemeVars(settings) {
  if (!settings || typeof settings !== 'object') return;
  const root = document.documentElement;
  Object.keys(THEME_VAR_MAP).forEach((key) => {
    if (!Object.prototype.hasOwnProperty.call(settings, key)) return; // 未指定 = 既定のまま
    const value = settings[key];
    if (typeof value === 'string' && value.trim() === '') {
      root.style.removeProperty(THEME_VAR_MAP[key]); // 空文字で明示的に解除
      return;
    }
    const hex = normalizeHex(value);
    if (hex) root.style.setProperty(THEME_VAR_MAP[key], hex); // 不正な hex は無視
  });
}

/* -------------------------------------------------------------------------- */
/* state                                                                       */
/* -------------------------------------------------------------------------- */

const DEFAULTS = {
  /* Swift 側 (ui-reader / Root SettingsView) が送るキー。値はすべて文字列。 */
  appName: 'PupilIOS',
  appVersion: '1.0.0',
  japaneseTitles: 'false',
  tagTranslation: '',
  tagTranslationLanguages: 'es,id,ko,zh',
  perPage: '20',
  theme: 'system',
  browseSort: 'dateAdded',
  browseLanguage: 'all',
  languages: 'all=すべて,ja=日本語,en=English,zh=中文,es=Español,id=Indonesia,ko=한국어',
  sortModes:
    'dateAdded=追加順,datePublished=公開順,popularToday=今日の人気,popularWeek=今週の人気,popularMonth=今月の人気,popularYear=今年の人気,random=ランダム',
};

function initialSurface() {
  try {
    const value = new URLSearchParams(window.location.search).get('surface');
    return value === 'about' ? 'about' : 'settings';
  } catch (err) {
    return 'settings';
  }
}

/** Astryx/Swift payload -> plain {key: string} map. Accepts a JSON string or object. */
function coerce(input) {
  let obj = input;
  if (typeof input === 'string') {
    try {
      obj = JSON.parse(input);
    } catch (err) {
      obj = {};
    }
  }
  if (!obj || typeof obj !== 'object') obj = {};
  const out = {};
  for (const key of Object.keys(obj)) {
    const value = obj[key];
    if (value === null || value === undefined) out[key] = '';
    else if (typeof value === 'boolean') out[key] = value ? 'true' : 'false';
    else out[key] = String(value);
  }
  return out;
}

let store = { surface: initialSurface(), settings: Object.assign({}, DEFAULTS) };
const listeners = new Set();

function emit() {
  const snapshot = { surface: store.surface, settings: Object.assign({}, store.settings) };
  listeners.forEach((listener) => listener(snapshot));
}

function applyPayload(input) {
  const next = coerce(input);
  store = { surface: store.surface, settings: Object.assign({}, store.settings, next) };
  applyThemeVars(next);
  emit();
  return true;
}

window.pupilUpdate = applyPayload;

window.PupilAstryx = {
  mount(surface) {
    store = { surface: surface === 'about' ? 'about' : 'settings', settings: store.settings };
    emit();
    return store.surface;
  },
  update: applyPayload,
  applyThemeVars,
  themeVarKeys: Object.keys(THEME_VAR_MAP),
  versions: {
    core: ASTRYX_CORE,
    theme: ASTRYX_THEME,
    react: REACT_VERSION,
    stylex: STYLEX_VERSION,
  },
};

function usePupilState() {
  const [snapshot, setSnapshot] = useState(() => ({
    surface: store.surface,
    settings: Object.assign({}, store.settings),
  }));

  useEffect(() => {
    const listener = (next) => setSnapshot(next);
    listeners.add(listener);
    listener({ surface: store.surface, settings: Object.assign({}, store.settings) });
    return () => {
      listeners.delete(listener);
    };
  }, []);

  return snapshot;
}

/* -------------------------------------------------------------------------- */
/* helpers                                                                     */
/* -------------------------------------------------------------------------- */

const bool = (value) => value === 'true' || value === '1' || value === 'on';

const PER_PAGE_MIN = 10;
const PER_PAGE_MAX = 100;
const PER_PAGE_STEP = 10;

function clampPerPage(current, delta) {
  const base = Number.parseInt(current, 10);
  const start = Number.isFinite(base) ? base : 20;
  const rounded = Math.round(start / PER_PAGE_STEP) * PER_PAGE_STEP;
  const next = Math.min(PER_PAGE_MAX, Math.max(PER_PAGE_MIN, rounded + delta));
  return String(next);
}

function languagesFrom(list) {
  return String(list || DEFAULTS.tagTranslationLanguages)
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

/** "id=ラベル,id=ラベル" -> [{id, label}]。Swift 側の [(id, label)] を平坦化した文字列用。 */
function parsePairs(text) {
  return String(text || '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean)
    .map((item) => {
      const at = item.indexOf('=');
      if (at < 0) return { id: item, label: item };
      const id = item.slice(0, at).trim();
      const label = item.slice(at + 1).trim();
      return { id, label: label || id };
    });
}

function ChoiceRow({ label, options, value, onSelect }) {
  if (options.length === 0) return null;
  return (
    <VStack gap={2}>
      <Text type="label">{label}</Text>
      <HStack gap={2} wrap="wrap">
        {options.map((option) => (
          <Button
            key={option.id}
            label={option.label}
            size="sm"
            variant={value === option.id ? 'primary' : 'secondary'}
            onClick={() => onSelect(option.id)}
          />
        ))}
      </HStack>
    </VStack>
  );
}

function LanguageSwitch({ settings, onChange }) {
  const languages = languagesFrom(settings.tagTranslationLanguages);
  const enabled = settings.tagTranslation !== '';
  return (
    <Switch
      label="タグ翻訳"
      description={
        enabled
          ? `タグ名を「${settings.tagTranslation}」で表示します`
          : 'Astryx のタグを端末内の辞書で翻訳します'
      }
      value={enabled}
      onChange={(next) => {
        if (next) onChange('tagTranslation', languages[0] || 'zh');
        else onChange('tagTranslation', '');
      }}
    />
  );
}

function ThemePicker({ value, onChange }) {
  const options = [
    { id: 'system', label: 'システム' },
    { id: 'dark', label: 'ダーク' },
    { id: 'light', label: 'ライト' },
  ];
  return (
    <VStack gap={2}>
      <ChoiceRow label="テーマ" options={options} value={value} onSelect={(id) => onChange('theme', id)} />
      <Text type="supporting" color="secondary">
        Astryx の面は常にダークトークンで描画しています（theme-neutral）。
      </Text>
    </VStack>
  );
}

function PerPageStepper({ value, onChange }) {
  const current = Number.parseInt(value, 10) || 20;
  return (
    <VStack gap={2}>
      <HStack gap={2} vAlign="center" hAlign="start">
        <Text type="label">1ページの件数</Text>
        <Badge label={String(current)} />
      </HStack>
      <HStack gap={2}>
        <Button
          label="−"
          size="sm"
          variant="secondary"
          isDisabled={current <= PER_PAGE_MIN}
          onClick={() => onChange('perPage', clampPerPage(value, -PER_PAGE_STEP))}
        />
        <Button
          label="＋"
          size="sm"
          variant="secondary"
          isDisabled={current >= PER_PAGE_MAX}
          onClick={() => onChange('perPage', clampPerPage(value, PER_PAGE_STEP))}
        />
        <Text type="supporting" color="secondary">
          {PER_PAGE_MIN}〜{PER_PAGE_MAX} 件（{PER_PAGE_STEP} 件刻み）
        </Text>
      </HStack>
    </VStack>
  );
}

/* -------------------------------------------------------------------------- */
/* surfaces                                                                    */
/* -------------------------------------------------------------------------- */

function SettingsSurface({ settings }) {
  const onChange = (key, value) => post('setting', { key, value });

  return (
    <VStack gap={4} padding={4} width="100%">
      <VStack gap={1}>
        <Heading level={1}>設定</Heading>
        <Text type="supporting" color="secondary">
          Astryx コンポーネントで描いた設定面です。Swift 側の設定と同じ値を共有します。
        </Text>
      </VStack>

      <Card padding={4}>
        <VStack gap={3}>
          <Heading level={3}>表示</Heading>
          <Switch
            label="日本語タイトル"
            description="Hitomi の japanese_title を優先して表示します"
            value={bool(settings.japaneseTitles)}
            onChange={(next) => onChange('japaneseTitles', next ? 'true' : 'false')}
          />
          <Divider />
          <LanguageSwitch settings={settings} onChange={onChange} />
        </VStack>
      </Card>

      <Card padding={4}>
        <VStack gap={3}>
          <Heading level={3}>ブラウズ</Heading>
          <PerPageStepper value={settings.perPage} onChange={onChange} />
          <Divider />
          <ChoiceRow
            label="ブラウズ言語"
            options={parsePairs(settings.languages)}
            value={settings.browseLanguage}
            onSelect={(id) => onChange('browseLanguage', id)}
          />
          <Divider />
          <ChoiceRow
            label="既定の並び順"
            options={parsePairs(settings.sortModes)}
            value={settings.browseSort}
            onSelect={(id) => onChange('browseSort', id)}
          />
          <Divider />
          <ThemePicker value={settings.theme} onChange={onChange} />
        </VStack>
      </Card>

      <HStack gap={2} vAlign="center" wrap="wrap" padding={1}>
        <Badge label={`perPage ${settings.perPage}`} />
        <Badge label={`sort ${settings.browseSort}`} />
        <Badge label={`lang ${settings.browseLanguage}`} />
        <Badge label={`tag ${settings.tagTranslation || 'off'}`} />
      </HStack>
    </VStack>
  );
}

function AboutSurface({ settings }) {
  const appName = settings.appName || DEFAULTS.appName;
  return (
    <VStack gap={4} padding={4} width="100%">
      <VStack gap={1}>
        <Heading level={1}>このアプリについて</Heading>
        <Text type="supporting" color="secondary">
          Hitomi.la ビューア Pupil の iOS 移植版
        </Text>
      </VStack>

      <Card padding={4}>
        <VStack gap={3}>
          <HStack gap={2} vAlign="center" wrap="wrap">
            <Heading level={2}>{appName}</Heading>
            <Badge label="GPLv3" />
          </HStack>
          <Text type="body">
            Android アプリ Pupil（Kotlin）の SwiftUI 移植です。ブラウズ・検索・お気に入り・履歴・
            リーダーを iOS 16 以降で動かします。
          </Text>
          <Text type="supporting" color="secondary">
            バージョン {settings.appVersion || DEFAULTS.appVersion}
          </Text>
          <Divider />
          <VStack gap={1}>
            <Text type="label">移植元</Text>
            <Text type="supporting" color="secondary">
              Pupil — codeberg.org/pupil/Pupil（GPLv3）
            </Text>
          </VStack>
          <Button
            label="移植元を開く"
            variant="secondary"
            size="sm"
            onClick={() => post('openurl', { url: SOURCE_REPO })}
          />
        </VStack>
      </Card>

      <Card padding={4}>
        <VStack gap={3}>
          <HStack gap={2} vAlign="center" wrap="wrap">
            <Heading level={3}>Astryx</Heading>
            <Badge label="MIT" />
          </HStack>
          <Text type="body">
            デザインシステムは Meta Open Source の Astryx を使っています。この画面を含む
            「設定」「このアプリについて」の 2 面は、本物の Astryx React コンポーネントを
            アプリに同梱したバンドルでオフライン描画しています。
          </Text>
          <Divider variant="subtle" />
          <VStack gap={1}>
            <Text type="supporting" color="secondary">
              @astryxdesign/core {ASTRYX_CORE}・@astryxdesign/theme-neutral {ASTRYX_THEME}
            </Text>
            <Text type="supporting" color="secondary">
              React {REACT_VERSION}・@stylexjs/stylex {STYLEX_VERSION}
            </Text>
            <Text type="supporting" color="secondary">
              外部 CDN 参照なし（フォントもバンドルに同梱）
            </Text>
          </VStack>
          <Button
            label="Astryx リポジトリ"
            variant="secondary"
            size="sm"
            onClick={() => post('openurl', { url: ASTRYX_REPO })}
          />
        </VStack>
      </Card>

      <Card padding={4} variant="muted">
        <VStack gap={2}>
          <Text type="label">ライセンス</Text>
          <Text type="supporting" color="secondary">
            PupilIOS は GPLv3 で配布されます。Astryx は MIT、React は MIT、Figtree は SIL OFL 1.1。
          </Text>
        </VStack>
      </Card>
    </VStack>
  );
}

/* -------------------------------------------------------------------------- */
/* root                                                                        */
/* -------------------------------------------------------------------------- */

function App() {
  const { surface, settings } = usePupilState();
  const reportedSurface = useRef(null);

  useEffect(() => {
    if (reportedSurface.current === surface) return;
    reportedSurface.current = surface;
    post('ready', { surface, core: ASTRYX_CORE });
  }, [surface]);

  const body = useMemo(
    () =>
      surface === 'about' ? (
        <AboutSurface settings={settings} />
      ) : (
        <SettingsSurface settings={settings} />
      ),
    [surface, settings]
  );

  return (
    <Theme theme={neutralTheme} mode="dark">
      {body}
    </Theme>
  );
}

const container = document.getElementById('root');
createRoot(container).render(<App />);
