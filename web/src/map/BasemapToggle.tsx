import { BASEMAP_THEMES, type BasemapTheme } from './basemap';

const LABELS: Record<BasemapTheme, string> = {
  light: 'Light',
  dark: 'Dark',
};

interface BasemapToggleProps {
  value: BasemapTheme;
  onChange: (theme: BasemapTheme) => void;
  disabled?: boolean;
}

/** Light or dark basemap, as a labelled radio group. */
export function BasemapToggle({ value, onChange, disabled = false }: BasemapToggleProps) {
  return (
    <fieldset className="basemap-toggle" disabled={disabled}>
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
