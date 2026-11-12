// Takes the map screenshots for scripts/screenshot.sh, inside the pinned
// Playwright image. Settings come from the environment:
//   SHOT_BASE    the web app's URL, for example http://web:8080/
//   SHOT_VIEWS   space-separated views, each zoom/lat/lon (MapLibre's hash)
//   SHOT_THEMES  space-separated basemap themes, as labelled in the app
//   SHOT_PREFIX  file name prefix; files go to /out
//   SHOT_WIDTH, SHOT_HEIGHT  viewport size in CSS pixels
//   SHOT_WAIT_MS settle time after the network goes quiet
// Prints one line per file, and any page errors, to stdout.
'use strict';

const { chromium } = require('playwright-core');

const env = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set`);
  return value;
};

const base = env('SHOT_BASE');
const views = env('SHOT_VIEWS').split(' ');
const themes = env('SHOT_THEMES').split(' ');
const prefix = env('SHOT_PREFIX');
const width = Number(env('SHOT_WIDTH'));
const height = Number(env('SHOT_HEIGHT'));
const waitMs = Number(env('SHOT_WAIT_MS'));

// The theme labels in web/src/map/BasemapToggle.tsx.
const LABELS = { light: 'Light', dark: 'Dark' };

async function settle(page) {
  await page.waitForLoadState('networkidle', { timeout: 60000 }).catch(() => {});
  await page.waitForTimeout(waitMs);
}

async function main() {
  const browser = await chromium.launch();
  let failed = false;
  try {
    for (const theme of themes) {
      for (const view of views) {
        const page = await browser.newPage({ viewport: { width, height } });
        page.on('pageerror', (err) => console.log(`page error: ${err.message}`));
        page.on('console', (msg) => {
          if (msg.type() === 'error') console.log(`console error: ${msg.text()}`);
        });
        await page.goto(`${base}#${view}`, { waitUntil: 'load' });
        await page.locator('.maplibregl-canvas').waitFor({ timeout: 30000 });
        await settle(page);
        if (theme !== 'light') {
          await page.getByLabel(LABELS[theme], { exact: true }).check();
          await settle(page);
        }
        const file = `${prefix}-${theme}-z${view.replace(/\//g, '_')}.png`;
        await page.screenshot({ path: `/out/${file}` });
        console.log(`wrote ${file}`);
        await page.close();
      }
    }
  } catch (err) {
    console.log(`error: ${err.message}`);
    failed = true;
  } finally {
    await browser.close();
  }
  if (failed) process.exitCode = 1;
}

void main();
