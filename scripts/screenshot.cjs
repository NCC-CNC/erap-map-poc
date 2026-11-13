// Takes the map screenshots for scripts/screenshot.sh, inside the pinned
// Playwright image. Settings come from the environment:
//   SHOT_BASE    the web app's URL, for example http://web:8080/
//   SHOT_VIEWS   space-separated views, each zoom/lat/lon (MapLibre's hash)
//   SHOT_THEMES  space-separated basemap themes, as labelled in the app
//   SHOT_PREFIX  file name prefix; files go to /out
//   SHOT_WIDTH, SHOT_HEIGHT  viewport size in CSS pixels
//   SHOT_WAIT_MS settle time after the network goes quiet
//   SHOT_CLICK   1 to click the map centre before the screenshot (optional)
//   SHOT_COLOUR_BY  space-separated LAYER=THEME colour theme choices
//                (optional)
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
const click = process.env.SHOT_CLICK === '1';
const colourBy = (process.env.SHOT_COLOUR_BY || '')
  .split(' ')
  .filter(Boolean)
  .map((choice) => choice.split('='));

// The theme labels in web/src/map/BasemapToggle.tsx.
const LABELS = { light: 'Light', dark: 'Dark' };

async function settle(page) {
  await page.waitForLoadState('networkidle', { timeout: 60000 }).catch(() => {});
  await page.waitForTimeout(waitMs);
}

/** Opens the layer panel if it starts collapsed (narrow screens). */
async function openPanel(page) {
  const panel = page.locator('details.map-panel');
  if ((await panel.getAttribute('open')) === null) await panel.locator('summary').click();
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
        // "Colour by" in web/src/map/LayerList.tsx: a select per layer.
        for (const [layer, choice] of colourBy) {
          await openPanel(page);
          await page.locator(`#layer-theme-${layer}`).selectOption(choice, { timeout: 10000 });
          await settle(page);
        }
        let file = `${prefix}-${theme}-z${view.replace(/\//g, '_')}`;
        if (click) {
          // The view's lat/lon is the centre of the map.
          const box = await page.locator('.maplibregl-canvas').boundingBox();
          await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
          await settle(page);
          const opened = await page.locator('[role="dialog"], .maplibregl-popup').count();
          if (!opened) console.log(`note: nothing to show at the centre of ${view}`);
          file += '-click';
        }
        file += '.png';
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
