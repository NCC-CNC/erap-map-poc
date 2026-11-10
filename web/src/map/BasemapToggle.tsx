import { BASEMAP_THEMES, type BasemapTheme } from './basemap';

const LABELS: Record<BasemapTheme, string> = {
  light: 'Light',
  dark: 'Dark',
};

interface BasemapToggleProps {
  value: BasemapTheme;
  onChange: (theme: BasemapTheme) => void;
}

/** Light or dark basemap, as a labelled radio group. */
export function BasemapToggle({ value, onChange }: BasemapToggleProps) {
  return (
    <fieldset className="basemap-toggle">
      <legend>Basemap</legend>
      {BASEMAP_THEMES.map((theme) => (
        <label key={theme}>
          <input
            type="radio"
            name="basemap"
            value={theme}
            checked={value === theme}
            onChange={() => onChange(theme)}
          />
          {LABELS[theme]}
        </label>
      ))}
    </fieldset>
  );
}
