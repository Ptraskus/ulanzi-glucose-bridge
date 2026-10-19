export const APP_LANGUAGES = Object.freeze(["en", "pt-BR"]);
let activeLanguage = null;

// CLI helpers can follow the configuration language without setting an
// environment override that would make the configuration editor read-only.
export function setAppLanguage(language) {
  activeLanguage = language === null ? null : language === "pt-BR" ? "pt-BR" : "en";
}

// Language is independent from the Windows regional format and glucose units.
// Unknown or missing preferences always fall back to English.
export function getAppLanguage(environment) {
  const preference = environment === undefined
    ? activeLanguage ?? process.env.APP_LANGUAGE
    : environment?.APP_LANGUAGE;
  return String(preference ?? "").trim().toLowerCase() === "pt-br"
    ? "pt-BR"
    : "en";
}

export function tr(english, portuguese, values = [], language = getAppLanguage()) {
  const template = language === "pt-BR" ? portuguese : english;
  return template.replace(/\{(\d+)\}/g, (placeholder, index) =>
    Number(index) < values.length ? String(values[Number(index)]) : placeholder);
}

export function displayUnitLabel(units) {
  return units === "mmol" ? "mmol/L" : "mg/dL";
}
