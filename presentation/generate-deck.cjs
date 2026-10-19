/*
 * Gera a apresentacao tecnica do Ulanzi Glucose Bridge.
 *
 * Uso:
 *   npm install --prefix <pasta-temporaria> pptxgenjs
 *   node presentation/generate-deck.cjs <pasta-temporaria>/node_modules/pptxgenjs
 */

const fs = require("node:fs");
const path = require("node:path");

const pptxModule = process.argv[2] || "pptxgenjs";
const PptxGenJS = require(pptxModule);
const pptx = new PptxGenJS();

pptx.layout = "LAYOUT_WIDE";
pptx.author = "Ulanzi Glucose Bridge contributors";
pptx.company = "Ulanzi Glucose Bridge";
pptx.subject = "Apresentacao tecnica da arquitetura e maturidade do software";
pptx.title = "Ulanzi Glucose Bridge — Apresentação técnica";
pptx.lang = "pt-BR";
pptx.theme = {
  headFontFace: "Aptos Display",
  bodyFontFace: "Aptos",
  lang: "pt-BR",
};
pptx.defineLayout({ name: "ULANZI_WIDE", width: 13.333, height: 7.5 });
pptx.layout = "ULANZI_WIDE";

const S = pptx.ShapeType;
const OUT = path.resolve(__dirname, "Ulanzi-Glucose-Bridge-Apresentacao-Tecnica.pptx");
const SCREENSHOT = path.resolve(__dirname, "..", "release", "install-smoke", "07-revisao.png");

const C = {
  bg: "08111F",
  bg2: "0C1728",
  panel: "101E31",
  panel2: "152842",
  border: "27415E",
  grid: "20344D",
  text: "F4F7FB",
  muted: "AAB7C9",
  faint: "71839B",
  cyan: "50B7FF",
  teal: "2DD4BF",
  green: "57E389",
  amber: "FFC857",
  orange: "FF8A5B",
  red: "FF6381",
  purple: "B494FF",
  white: "FFFFFF",
  black: "000000",
};

const F = {
  head: "Aptos Display",
  body: "Aptos",
  mono: "Cascadia Mono",
};

const W = 13.333;
const H = 7.5;

const PORTUGUESE_WORDS = {
  apresentacao: "apresentação",
  tecnica: "técnica",
  tecnico: "técnico",
  visao: "visão",
  versao: "versão",
  relogio: "relógio",
  relogios: "relógios",
  logica: "lógica",
  proprio: "próprio",
  efemero: "efêmero",
  sao: "são",
  tres: "três",
  util: "útil",
  decisao: "decisão",
  tendencia: "tendência",
  tendencias: "tendências",
  nao: "não",
  medico: "médico",
  glicosimetro: "glicosímetro",
  preferencia: "preferência",
  confianca: "confiança",
  inspecionavel: "inspecionável",
  configuracao: "configuração",
  supervisao: "supervisão",
  servico: "serviço",
  normalizacao: "normalização",
  classificacao: "classificação",
  verificavel: "verificável",
  dominio: "domínio",
  saida: "saída",
  horario: "horário",
  exibicao: "exibição",
  numericos: "numéricos",
  confirmacoes: "confirmações",
  sessao: "sessão",
  regressao: "regressão",
  resiliencia: "resiliência",
  ultima: "última",
  renovacao: "renovação",
  apos: "após",
  maquina: "máquina",
  episodios: "episódios",
  episodio: "episódio",
  confirmacao: "confirmação",
  persistencia: "persistência",
  reinicio: "reinício",
  instalacao: "instalação",
  automatica: "automática",
  deteccao: "detecção",
  diferencas: "diferenças",
  instalacoes: "instalações",
  inicializacao: "inicialização",
  revisao: "revisão",
  experiencia: "experiência",
  reiniciavel: "reiniciável",
  atomico: "atômico",
  minimizacao: "minimização",
  explicita: "explícita",
  coerencia: "coerência",
  prioritarios: "prioritários",
  momentanea: "momentânea",
  configuraveis: "configuráveis",
  duplicacao: "duplicação",
  auditavel: "auditável",
  unica: "única",
  verificacao: "verificação",
  autenticacao: "autenticação",
  ja: "já",
  separacao: "separação",
  sintetico: "sintético",
  confiavel: "confiável",
  validacao: "validação",
  obrigatorio: "obrigatório",
  usuario: "usuário",
  sanitizacao: "sanitização",
  atomica: "atômica",
  instancia: "instância",
  saudavel: "saudável",
  saude: "saúde",
  automatico: "automático",
  rotacao: "rotação",
  diagnostico: "diagnóstico",
  fisico: "físico",
  evidencia: "evidência",
  modulos: "módulos",
  funcoes: "funções",
  integracao: "integração",
  conclusao: "conclusão",
  nucleo: "núcleo",
  explicito: "explícito",
  dependencias: "dependências",
  recuperacao: "recuperação",
  implicitas: "implícitas",
  intermediaria: "intermediária",
  seguranca: "segurança",
  proximos: "próximos",
  autonomo: "autônomo",
  alem: "além",
  aparencia: "aparência",
  ate: "até",
  padrao: "padrão",
  numero: "número",
  expiracao: "expiração",
  execucao: "execução",
  operacao: "operação",
  relacao: "relação",
  media: "média",
  suite: "suíte",
  so: "só",
};

const portuguesePattern = new RegExp(`\\b(${Object.keys(PORTUGUESE_WORDS).join("|")})\\b`, "gi");

function localizePortuguese(value) {
  if (typeof value !== "string") return value;
  const protectedTokens = [];
  const protectedValue = value.replace(
    /(?:https?:\/\/[^\s,;]+|\/api\/[A-Za-z0-9_./{}?&=-]+|(?:[A-Za-z0-9_*{}.-]+[\\/])+[A-Za-z0-9_*{}.?&=:-]+|[A-Za-z0-9_-]+\.(?:md|mjs|ps1|json|cmd|exe|pptx))/g,
    (token) => {
      const marker = `ZXQCODE${protectedTokens.length}QXZ`;
      protectedTokens.push(token);
      return marker;
    },
  );
  let localized = protectedValue.replace(portuguesePattern, (match) => {
    const replacement = PORTUGUESE_WORDS[match.toLowerCase()];
    if (match === match.toUpperCase()) return replacement.toUpperCase();
    if (match[0] === match[0].toUpperCase()) {
      return `${replacement[0].toUpperCase()}${replacement.slice(1)}`;
    }
    return replacement;
  });
  localized = localized
    .replace(/\bnão e\b/g, "não é")
    .replace(/\bNão e\b/g, "Não é")
    .replace(/\bNAO E\b/g, "NÃO É")
    .replace(/\bO relógio e\b/g, "O relógio é")
    .replace(/\bO PC e\b/g, "O PC é")
    .replace(/\bA preferência e por\b/g, "A preferência é por")
    .replace(/\bnão esta\b/g, "não está")
    .replace(/\bautorizado e a entrada\b/g, "autorizado é a entrada")
    .replace(/\bTC001 e somente\b/g, "TC001 é somente")
    .replace(/\bfontes e estrutural\b/g, "fontes é estrutural")
    .replace(/\bNão ha\b/g, "Não há")
    .replace(/\bvalidade e parte\b/g, "validade é parte")
    .replace(/\bEsta e a principal\b/g, "Esta é a principal")
    .replace(/\bsó e exposto\b/g, "só é exposto")
    .replace(/\bcadeia real e atalho\b/g, "cadeia real é atalho")
    .replace(/\barquivos e simples\b/g, "arquivos é simples")
    .replace(/\bredirect e manual\b/g, "redirect é manual")
    .replace(/\bseparação e um\b/g, "separação é um")
    .replace(/\blacuna mais clara e\b/g, "lacuna mais clara é")
    .replace(/\batual esta\b/g, "atual está")
    .replace(/\bleitura valida\b/g, "leitura válida")
    .replace(/\bESTA BEM RESOLVIDO\b/g, "ESTÁ BEM RESOLVIDO")
    .replace(/\besta bem resolvido\b/g, "está bem resolvido")
    .replace(/\bconfiança publica\b/g, "confiança pública")
    .replace(/\bpre-publicacao\b/gi, (match) => match === match.toUpperCase() ? "PRÉ-PUBLICAÇÃO" : "pré-publicação")
    .replace(/\bpublicacao\b/gi, (match) => match === match.toUpperCase() ? "PUBLICAÇÃO" : "publicação");
  localized = localized.replace(/ZXQCODE(\d+)QXZ/g, (_marker, index) => protectedTokens[Number(index)]);
  return localized;
}

function newSlide() {
  const slide = pptx.addSlide();
  const originalAddText = slide.addText.bind(slide);
  const originalAddNotes = slide.addNotes.bind(slide);
  slide.addText = (text, options) => originalAddText(localizePortuguese(text), options);
  slide.addNotes = (notes) => originalAddNotes(localizePortuguese(notes));
  return slide;
}

function addBackground(slide, { grid = true } = {}) {
  slide.background = { color: C.bg };
  slide.addShape(S.rect, {
    x: 0,
    y: 0,
    w: W,
    h: H,
    fill: { color: C.bg },
    line: { color: C.bg, transparency: 100 },
  });
  slide.addShape(S.rect, {
    x: 0,
    y: 0,
    w: W,
    h: 0.08,
    fill: { color: C.teal },
    line: { color: C.teal, transparency: 100 },
  });
  if (grid) {
    for (let x = 0.5; x < W; x += 0.5) {
      slide.addShape(S.line, {
        x,
        y: 0.08,
        w: 0,
        h: H - 0.08,
        line: { color: C.grid, transparency: 84, width: 0.3 },
      });
    }
    for (let y = 0.58; y < H; y += 0.5) {
      slide.addShape(S.line, {
        x: 0,
        y,
        w: W,
        h: 0,
        line: { color: C.grid, transparency: 86, width: 0.3 },
      });
    }
  }
}

function addFooter(slide, number, label = "VISAO TECNICA") {
  slide.addShape(S.line, {
    x: 0.58,
    y: 7.16,
    w: 12.17,
    h: 0,
    line: { color: C.border, width: 0.7 },
  });
  slide.addText(`ULANZI GLUCOSE BRIDGE  /  ${label}`, {
    x: 0.62,
    y: 7.19,
    w: 4.7,
    h: 0.16,
    fontFace: F.body,
    fontSize: 7.5,
    color: C.faint,
    charSpacing: 1.2,
    margin: 0,
  });
  slide.addText(String(number).padStart(2, "0"), {
    x: 12.25,
    y: 7.17,
    w: 0.45,
    h: 0.2,
    fontFace: F.mono,
    fontSize: 8.5,
    bold: true,
    color: C.teal,
    align: "right",
    margin: 0,
  });
}

function addHeader(slide, number, kicker, title, subtitle = null) {
  addBackground(slide);
  slide.addText(kicker.toUpperCase(), {
    x: 0.65,
    y: 0.33,
    w: 4.7,
    h: 0.2,
    fontFace: F.body,
    fontSize: 8.5,
    bold: true,
    color: C.teal,
    charSpacing: 1.8,
    margin: 0,
  });
  slide.addText(title, {
    x: 0.63,
    y: 0.62,
    w: 11.95,
    h: 0.58,
    fontFace: F.head,
    fontSize: 26,
    bold: true,
    color: C.text,
    margin: 0,
    fit: "shrink",
  });
  if (subtitle) {
    slide.addText(subtitle, {
      x: 0.65,
      y: 1.19,
      w: 11.7,
      h: 0.3,
      fontFace: F.body,
      fontSize: 11.2,
      color: C.muted,
      margin: 0,
      fit: "shrink",
    });
  }
  addFooter(slide, number);
}

function addPill(slide, text, x, y, w, {
  color = C.teal,
  fill = C.panel2,
  fontSize = 9.5,
  outline = color,
} = {}) {
  slide.addShape(S.roundRect, {
    x,
    y,
    w,
    h: 0.34,
    rectRadius: 0.08,
    fill: { color: fill },
    line: { color: outline, width: 0.8, transparency: 28 },
  });
  slide.addText(text, {
    x: x + 0.08,
    y: y + 0.055,
    w: w - 0.16,
    h: 0.18,
    fontFace: F.body,
    fontSize,
    bold: true,
    color,
    align: "center",
    margin: 0,
    fit: "shrink",
  });
}

function addCard(slide, { x, y, w, h, title, body, accent = C.teal, label = null, mono = false }) {
  slide.addShape(S.roundRect, {
    x,
    y,
    w,
    h,
    rectRadius: 0.08,
    fill: { color: C.panel, transparency: 2 },
    line: { color: C.border, width: 1 },
  });
  slide.addShape(S.rect, {
    x,
    y,
    w: 0.07,
    h,
    fill: { color: accent },
    line: { color: accent, transparency: 100 },
  });
  if (label) {
    slide.addText(label.toUpperCase(), {
      x: x + 0.25,
      y: y + 0.18,
      w: w - 0.45,
      h: 0.16,
      fontFace: F.body,
      fontSize: 7.5,
      bold: true,
      color: accent,
      charSpacing: 1.2,
      margin: 0,
    });
  }
  const titleY = y + (label ? 0.46 : 0.24);
  slide.addText(title, {
    x: x + 0.25,
    y: titleY,
    w: w - 0.45,
    h: 0.34,
    fontFace: F.head,
    fontSize: 16,
    bold: true,
    color: C.text,
    margin: 0,
    fit: "shrink",
  });
  if (body) {
    const bodyHeight = Math.max(0.12, h - (titleY - y) - 0.65);
    slide.addText(body, {
      x: x + 0.25,
      y: titleY + 0.5,
      w: w - 0.46,
      h: bodyHeight,
      fontFace: mono ? F.mono : F.body,
      fontSize: mono ? 10 : 11.1,
      color: C.muted,
      breakLine: false,
      margin: 0,
      valign: "top",
      fit: "shrink",
    });
  }
}

function addBullet(slide, text, x, y, w, {
  accent = C.teal,
  color = C.text,
  fontSize = 11.2,
  h = 0.36,
} = {}) {
  slide.addShape(S.ellipse, {
    x,
    y: y + 0.11,
    w: 0.09,
    h: 0.09,
    fill: { color: accent },
    line: { color: accent, transparency: 100 },
  });
  slide.addText(text, {
    x: x + 0.18,
    y,
    w: w - 0.18,
    h,
    fontFace: F.body,
    fontSize,
    color,
    margin: 0,
    fit: "shrink",
  });
}

function addArrow(slide, x1, y1, x2, y2, { color = C.cyan, width = 1.5, dash = "solid" } = {}) {
  const reverse = x2 < x1 || (x2 === x1 && y2 < y1);
  slide.addShape(S.line, {
    x: Math.min(x1, x2),
    y: Math.min(y1, y2),
    w: Math.abs(x2 - x1),
    h: Math.abs(y2 - y1),
    line: {
      color,
      width,
      dashType: dash,
      beginArrowType: reverse ? "triangle" : undefined,
      endArrowType: reverse ? undefined : "triangle",
    },
  });
}

function addMetric(slide, value, label, x, y, w, { accent = C.teal, note = null } = {}) {
  slide.addShape(S.roundRect, {
    x,
    y,
    w,
    h: note ? 1.05 : 0.88,
    rectRadius: 0.07,
    fill: { color: C.panel },
    line: { color: C.border, width: 0.9 },
  });
  slide.addText(value, {
    x: x + 0.15,
    y: y + 0.12,
    w: w - 0.3,
    h: 0.38,
    fontFace: F.head,
    fontSize: 23,
    bold: true,
    color: accent,
    align: "center",
    margin: 0,
    fit: "shrink",
  });
  slide.addText(label.toUpperCase(), {
    x: x + 0.12,
    y: y + 0.57,
    w: w - 0.24,
    h: 0.14,
    fontFace: F.body,
    fontSize: 7.6,
    bold: true,
    color: C.muted,
    align: "center",
    charSpacing: 1,
    margin: 0,
    fit: "shrink",
  });
  if (note) {
    slide.addText(note, {
      x: x + 0.1,
      y: y + 0.78,
      w: w - 0.2,
      h: 0.14,
      fontFace: F.body,
      fontSize: 7.3,
      color: C.faint,
      align: "center",
      margin: 0,
      fit: "shrink",
    });
  }
}

function addSectionLabel(slide, text, x, y, w, accent = C.cyan) {
  slide.addText(text.toUpperCase(), {
    x,
    y,
    w,
    h: 0.16,
    fontFace: F.body,
    fontSize: 7.5,
    bold: true,
    color: accent,
    charSpacing: 1.4,
    margin: 0,
  });
}

function addMiniLed(slide, x, y, w = 1.15, color = C.green, text = "112 ↑") {
  slide.addShape(S.roundRect, {
    x,
    y,
    w,
    h: 0.48,
    rectRadius: 0.04,
    fill: { color: "050A10" },
    line: { color: C.border, width: 0.8 },
  });
  slide.addText(text, {
    x: x + 0.08,
    y: y + 0.09,
    w: w - 0.16,
    h: 0.23,
    fontFace: F.mono,
    fontSize: 14,
    bold: true,
    color,
    align: "center",
    margin: 0,
    fit: "shrink",
  });
}

function addLedMatrix(slide, x, y) {
  const cols = 32;
  const rows = 8;
  const gap = 0.018;
  const cell = 0.105;
  const panelW = cols * (cell + gap) + 0.24;
  const panelH = rows * (cell + gap) + 0.24;
  slide.addShape(S.roundRect, {
    x,
    y,
    w: panelW,
    h: panelH,
    rectRadius: 0.05,
    fill: { color: "03070B" },
    line: { color: C.border, width: 1.1 },
  });

  const glyphs = {
    "1": ["010", "110", "010", "010", "010", "010", "111"],
    "2": ["11110", "00001", "00001", "11110", "10000", "10000", "11111"],
    up: ["00100", "01110", "10101", "00100", "00100", "00100", "00100"],
  };
  const pixels = new Set();
  function stamp(pattern, ox, oy) {
    pattern.forEach((row, py) => {
      [...row].forEach((v, px) => {
        if (v === "1") pixels.add(`${ox + px}:${oy + py}`);
      });
    });
  }
  stamp(glyphs["1"], 5, 0);
  stamp(glyphs["1"], 10, 0);
  stamp(glyphs["2"], 15, 0);
  stamp(glyphs.up, 24, 0);
  for (let row = 0; row < rows; row += 1) {
    for (let col = 0; col < cols; col += 1) {
      const on = pixels.has(`${col}:${row}`);
      slide.addShape(S.rect, {
        x: x + 0.12 + col * (cell + gap),
        y: y + 0.12 + row * (cell + gap),
        w: cell,
        h: cell,
        fill: { color: on ? C.green : "132235", transparency: on ? 0 : 30 },
        line: { color: on ? C.green : "132235", transparency: 100 },
      });
    }
  }
}

function addCodeBox(slide, code, x, y, w, h, { title = null, accent = C.cyan, fontSize = 10.5 } = {}) {
  slide.addShape(S.roundRect, {
    x,
    y,
    w,
    h,
    rectRadius: 0.06,
    fill: { color: "050C16" },
    line: { color: C.border, width: 1 },
  });
  slide.addShape(S.ellipse, {
    x: x + 0.18,
    y: y + 0.17,
    w: 0.09,
    h: 0.09,
    fill: { color: C.red },
    line: { color: C.red, transparency: 100 },
  });
  slide.addShape(S.ellipse, {
    x: x + 0.33,
    y: y + 0.17,
    w: 0.09,
    h: 0.09,
    fill: { color: C.amber },
    line: { color: C.amber, transparency: 100 },
  });
  slide.addShape(S.ellipse, {
    x: x + 0.48,
    y: y + 0.17,
    w: 0.09,
    h: 0.09,
    fill: { color: C.green },
    line: { color: C.green, transparency: 100 },
  });
  if (title) {
    slide.addText(title, {
      x: x + 0.72,
      y: y + 0.12,
      w: w - 0.9,
      h: 0.16,
      fontFace: F.mono,
      fontSize: 7.5,
      color: C.faint,
      margin: 0,
      fit: "shrink",
    });
  }
  slide.addShape(S.line, {
    x: x + 0.02,
    y: y + 0.39,
    w: w - 0.04,
    h: 0,
    line: { color: C.border, width: 0.6 },
  });
  slide.addText(code, {
    x: x + 0.22,
    y: y + 0.55,
    w: w - 0.44,
    h: h - 0.72,
    fontFace: F.mono,
    fontSize,
    color: accent,
    margin: 0,
    breakLine: false,
    valign: "top",
    fit: "shrink",
  });
}

function addCoverageBar(slide, label, value, y, color) {
  const x = 0.86;
  const w = 4.75;
  slide.addText(label, {
    x,
    y: y - 0.03,
    w: 1.05,
    h: 0.2,
    fontFace: F.body,
    fontSize: 9.3,
    bold: true,
    color: C.muted,
    margin: 0,
  });
  slide.addShape(S.roundRect, {
    x: x + 1.15,
    y,
    w: w - 1.15,
    h: 0.16,
    rectRadius: 0.04,
    fill: { color: C.panel2 },
    line: { color: C.panel2, transparency: 100 },
  });
  slide.addShape(S.roundRect, {
    x: x + 1.15,
    y,
    w: (w - 1.15) * (value / 100),
    h: 0.16,
    rectRadius: 0.04,
    fill: { color },
    line: { color, transparency: 100 },
  });
  slide.addText(`${value.toFixed(2).replace(".", ",")}%`, {
    x: x + w + 0.12,
    y: y - 0.06,
    w: 0.66,
    h: 0.22,
    fontFace: F.mono,
    fontSize: 9,
    bold: true,
    color,
    align: "right",
    margin: 0,
  });
}

// Slide 1 — capa
{
  const slide = newSlide();
  addBackground(slide);
  slide.addText("APRESENTACAO TECNICA", {
    x: 0.7,
    y: 0.48,
    w: 3.8,
    h: 0.22,
    fontFace: F.body,
    fontSize: 9,
    bold: true,
    color: C.teal,
    charSpacing: 2,
    margin: 0,
  });
  slide.addText("Ulanzi\nGlucose Bridge", {
    x: 0.66,
    y: 1.0,
    w: 6.1,
    h: 1.55,
    fontFace: F.head,
    fontSize: 37,
    bold: true,
    color: C.text,
    breakLine: false,
    margin: 0,
    fit: "shrink",
  });
  slide.addText("Uma ponte local entre uma fonte autorizada de glicemia e o TC001 — com tempo, falhas e privacidade tratados como parte do dominio.", {
    x: 0.7,
    y: 2.86,
    w: 5.7,
    h: 0.86,
    fontFace: F.body,
    fontSize: 16,
    color: C.muted,
    margin: 0,
    fit: "shrink",
  });
  addPill(slide, "NODE.JS 22+", 0.7, 4.05, 1.45, { color: C.green });
  addPill(slide, "POWERSHELL / WINFORMS", 2.28, 4.05, 2.42, { color: C.cyan });
  addPill(slide, "AWTRIX NG + 3", 4.83, 4.05, 1.55, { color: C.amber });
  slide.addShape(S.line, {
    x: 0.7,
    y: 4.74,
    w: 5.68,
    h: 0,
    line: { color: C.border, width: 1 },
  });
  slide.addText("VERSAO ANALISADA", {
    x: 0.7,
    y: 5.0,
    w: 1.7,
    h: 0.18,
    fontFace: F.body,
    fontSize: 7.5,
    bold: true,
    color: C.faint,
    charSpacing: 1.2,
    margin: 0,
  });
  slide.addText("0.1.0  /  30 ago 2026", {
    x: 0.7,
    y: 5.28,
    w: 3.3,
    h: 0.3,
    fontFace: F.mono,
    fontSize: 14,
    bold: true,
    color: C.text,
    margin: 0,
  });
  slide.addText("Para uma conversa entre programadores", {
    x: 0.7,
    y: 6.38,
    w: 4.4,
    h: 0.25,
    fontFace: F.body,
    fontSize: 10,
    color: C.faint,
    italic: true,
    margin: 0,
  });

  slide.addShape(S.roundRect, {
    x: 7.05,
    y: 0.72,
    w: 5.62,
    h: 5.98,
    rectRadius: 0.09,
    fill: { color: C.bg2 },
    line: { color: C.border, width: 1.2 },
  });
  addSectionLabel(slide, "o que chega ao relogio", 7.53, 1.08, 3.5, C.green);
  addLedMatrix(slide, 7.52, 1.46);
  slide.addText("Valor + tendencia + estado visual", {
    x: 7.54,
    y: 2.72,
    w: 4.55,
    h: 0.28,
    fontFace: F.body,
    fontSize: 11.2,
    color: C.muted,
    align: "center",
    margin: 0,
  });
  addSectionLabel(slide, "o caminho", 7.53, 3.36, 2.2, C.cyan);
  addCard(slide, {
    x: 7.54,
    y: 3.72,
    w: 1.35,
    h: 1.3,
    title: "Fonte",
    body: "Nightscout\nJSON / mock",
    accent: C.purple,
  });
  addCard(slide, {
    x: 9.34,
    y: 3.72,
    w: 1.55,
    h: 1.3,
    title: "Bridge",
    body: "regra local\n+ estado",
    accent: C.teal,
  });
  addCard(slide, {
    x: 11.34,
    y: 3.72,
    w: 0.95,
    h: 1.3,
    title: "TC001",
    body: "display\n+ som",
    accent: C.green,
  });
  addArrow(slide, 8.9, 4.37, 9.26, 4.37, { color: C.cyan });
  addArrow(slide, 10.9, 4.37, 11.26, 4.37, { color: C.cyan });
  slide.addShape(S.roundRect, {
    x: 7.54,
    y: 5.46,
    w: 4.75,
    h: 0.72,
    rectRadius: 0.05,
    fill: { color: "14293A" },
    line: { color: C.teal, width: 0.8, transparency: 35 },
  });
  slide.addText("Credenciais, limites e logica permanecem no PC.", {
    x: 7.76,
    y: 5.67,
    w: 4.3,
    h: 0.27,
    fontFace: F.body,
    fontSize: 11.5,
    bold: true,
    color: C.teal,
    align: "center",
    margin: 0,
    fit: "shrink",
  });
  slide.addNotes("Abra com a tese: o valor do projeto nao esta apenas em mostrar um numero. O desenho trata validade temporal, confirmacao de entrega, privacidade e recuperacao. Versao analisada: package.json 0.1.0. Fontes: README.md:3-9; package.json.");
}

// Slide 2 — problema e escopo
{
  const slide = newSlide();
  addHeader(slide, 2, "Problema e fronteira", "O problema, em uma frase", "Entregar um estado simples ao relogio sem transformar o relogio no sistema de verdade.");
  addCard(slide, {
    x: 0.7,
    y: 1.72,
    w: 3.55,
    h: 1.85,
    label: "entrada",
    title: "Fonte autorizada",
    body: "Nightscout proprio, endpoint JSON local/autorizado ou fonte mock para teste.",
    accent: C.purple,
  });
  addCard(slide, {
    x: 4.9,
    y: 1.72,
    w: 3.55,
    h: 1.85,
    label: "decisao",
    title: "Bridge local",
    body: "Normaliza, valida horario, calcula estado, agenda alarmes e publica saude.",
    accent: C.teal,
  });
  addCard(slide, {
    x: 9.1,
    y: 1.72,
    w: 3.55,
    h: 1.85,
    label: "saida",
    title: "TC001 / AWTRIX",
    body: "Recebe apenas valor, tendencia, estado visual e comandos sonoros.",
    accent: C.green,
  });
  addArrow(slide, 4.28, 2.64, 4.82, 2.64, { color: C.cyan, width: 2 });
  addArrow(slide, 8.48, 2.64, 9.02, 2.64, { color: C.cyan, width: 2 });

  slide.addShape(S.roundRect, {
    x: 0.7,
    y: 4.18,
    w: 7.45,
    h: 1.82,
    rectRadius: 0.08,
    fill: { color: "10283A" },
    line: { color: C.teal, width: 1 },
  });
  addSectionLabel(slide, "decisao arquitetural", 1.0, 4.46, 2.7, C.teal);
  slide.addText("O PC e o trust boundary.\nO relogio e um terminal efemero.", {
    x: 1.0,
    y: 4.82,
    w: 6.75,
    h: 0.84,
    fontFace: F.head,
    fontSize: 22,
    bold: true,
    color: C.text,
    margin: 0,
    fit: "shrink",
  });

  slide.addShape(S.roundRect, {
    x: 8.45,
    y: 4.18,
    w: 4.2,
    h: 1.82,
    rectRadius: 0.08,
    fill: { color: "2A1720" },
    line: { color: C.red, width: 1, transparency: 20 },
  });
  addSectionLabel(slide, "fora de escopo", 8.76, 4.46, 2.1, C.red);
  addBullet(slide, "Sem login na nuvem do fabricante", 8.78, 4.78, 3.48, { accent: C.red, fontSize: 10.3 });
  addBullet(slide, "Nao e dispositivo medico", 8.78, 5.16, 3.48, { accent: C.red, fontSize: 10.3 });
  addBullet(slide, "Nao substitui app nem glicosimetro", 8.78, 5.54, 3.48, { accent: C.red, fontSize: 10.3 });
  slide.addText("A preferencia e por indisponibilidade explicita, nunca por confianca falsa.", {
    x: 0.72,
    y: 6.37,
    w: 11.9,
    h: 0.32,
    fontFace: F.body,
    fontSize: 12,
    bold: true,
    color: C.amber,
    align: "center",
    margin: 0,
  });
  slide.addNotes("Explique a fronteira: o projeto nao recebe a senha da nuvem do fabricante nem se conecta diretamente ao sensor. Nightscout ou JSON autorizado e a entrada, independentemente da marca do CGM; o TC001 e somente exibicao ou aviso. O software nao e dispositivo medico. Fontes: README.md; GUIA-NIGHTSCOUT.md.");
}

// Slide 3 — arquitetura
{
  const slide = newSlide();
  addHeader(slide, 3, "Arquitetura", "Data plane Node.js + control plane Windows", "Dois processos, responsabilidades distintas e IPC local inspecionavel.");
  addSectionLabel(slide, "fontes externas", 0.68, 1.66, 2.3, C.purple);
  addCard(slide, { x: 0.68, y: 1.98, w: 2.1, h: 0.88, title: "Nightscout", body: "SGV + sessao", accent: C.purple });
  addCard(slide, { x: 0.68, y: 3.02, w: 2.1, h: 0.88, title: "JSON", body: "contrato simples", accent: C.cyan });
  addCard(slide, { x: 0.68, y: 4.06, w: 2.1, h: 0.88, title: "Mock", body: "teste / demo", accent: C.amber });

  slide.addShape(S.roundRect, {
    x: 3.28,
    y: 1.69,
    w: 6.42,
    h: 3.55,
    rectRadius: 0.08,
    fill: { color: C.bg2 },
    line: { color: C.teal, width: 1.2 },
  });
  addSectionLabel(slide, "data plane  /  node.js esm", 3.58, 1.95, 3.4, C.teal);
  const pipeline = [
    ["source-factory", C.purple],
    ["normalizeReading", C.cyan],
    ["display state", C.teal],
    ["AwtrixClient", C.green],
  ];
  pipeline.forEach(([label, color], i) => {
    const x = 3.58 + i * 1.48;
    addPill(slide, label, x, 2.45, 1.27, { color, fontSize: 7.5 });
    if (i < pipeline.length - 1) addArrow(slide, x + 1.28, 2.62, x + 1.43, 2.62, { color: C.faint, width: 1 });
  });
  addCard(slide, {
    x: 3.58,
    y: 3.22,
    w: 2.72,
    h: 1.42,
    title: "GlucoseAlarmTracker",
    body: "episodios, prioridade, retry, snapshot",
    accent: C.orange,
  });
  addCard(slide, {
    x: 6.58,
    y: 3.22,
    w: 2.72,
    h: 1.42,
    title: "runtime-status v2",
    body: "health por subsistema + IPC",
    accent: C.cyan,
  });
  addArrow(slide, 2.82, 3.46, 3.19, 3.46, { color: C.cyan, width: 1.6 });

  addSectionLabel(slide, "dispositivo", 10.28, 1.66, 1.7, C.green);
  slide.addShape(S.roundRect, {
    x: 10.2,
    y: 2.1,
    w: 2.45,
    h: 2.44,
    rectRadius: 0.08,
    fill: { color: "0B161A" },
    line: { color: C.green, width: 1.2, transparency: 20 },
  });
  addMiniLed(slide, 10.84, 2.48, 1.17, C.green);
  slide.addText("TC001", {
    x: 10.52,
    y: 3.18,
    w: 1.8,
    h: 0.35,
    fontFace: F.head,
    fontSize: 18,
    bold: true,
    color: C.text,
    align: "center",
    margin: 0,
  });
  slide.addText("AWTRIX NG / 3\nHTTP na LAN", {
    x: 10.52,
    y: 3.66,
    w: 1.8,
    h: 0.48,
    fontFace: F.body,
    fontSize: 9.7,
    color: C.muted,
    align: "center",
    margin: 0,
  });
  addArrow(slide, 9.75, 3.26, 10.12, 3.26, { color: C.green, width: 1.8 });

  slide.addShape(S.roundRect, {
    x: 0.68,
    y: 5.5,
    w: 11.97,
    h: 1.12,
    rectRadius: 0.07,
    fill: { color: C.panel },
    line: { color: C.border, width: 1 },
  });
  addSectionLabel(slide, "control plane  /  powershell 5.1 + winforms", 0.96, 5.73, 4.3, C.cyan);
  addPill(slide, "TRAY + PAINEL", 0.96, 6.05, 1.46, { color: C.cyan, fontSize: 8 });
  addArrow(slide, 2.45, 6.22, 2.76, 6.22, { color: C.faint, width: 1 });
  addPill(slide, "STATUS / COMMAND / STOP", 2.82, 6.05, 2.15, { color: C.amber, fontSize: 8 });
  addArrow(slide, 5.0, 6.22, 5.31, 6.22, { color: C.faint, width: 1 });
  addPill(slide, ".ENV + VAULT DPAPI", 5.37, 6.05, 1.86, { color: C.purple, fontSize: 8 });
  addArrow(slide, 7.26, 6.22, 7.57, 6.22, { color: C.faint, width: 1 });
  addPill(slide, "SUPERVISAO DO NODE", 7.63, 6.05, 1.92, { color: C.teal, fontSize: 8 });
  slide.addText("Sem Electron. Sem servico do Windows.", {
    x: 9.78,
    y: 6.08,
    w: 2.5,
    h: 0.25,
    fontFace: F.body,
    fontSize: 9.5,
    bold: true,
    color: C.muted,
    align: "right",
    margin: 0,
  });
  slide.addNotes("Use os termos data plane e control plane. O Node faz dominio e integracao; PowerShell/WinForms supervisiona, configura e apresenta. A interface das fontes e estrutural: getReading(now, signal) e getSensorSession opcional. Nao ha dependencias npm de runtime. Fontes: src/index.mjs:668-708; src/source-factory.mjs; scripts/iniciar-bandeja.ps1; package.json.");
}

// Slide 4 — contrato de dominio
{
  const slide = newSlide();
  addHeader(slide, 4, "Dominio", "Uma leitura entra; um estado com validade sai", "A normalizacao reduz formatos diferentes a um contrato pequeno e verificavel.");
  addCodeBox(slide,
`{
  valueMgDl: 112,
  trend: "flat",
  timestamp: Date,
  source: "Nightscout"
}`,
    0.7, 1.72, 5.05, 2.38,
    { title: "normalizeReading()", accent: C.cyan, fontSize: 13 },
  );
  addSectionLabel(slide, "invariantes de entrada", 0.75, 4.42, 2.7, C.cyan);
  addBullet(slide, "valor finito, positivo e <= 1000 mg/dL", 0.78, 4.76, 4.85, { accent: C.cyan, fontSize: 10.4 });
  addBullet(slide, "timestamp ISO ou epoch; futuro > 5 min e rejeitado", 0.78, 5.19, 4.85, { accent: C.cyan, fontSize: 10.4 });
  addBullet(slide, "tendencias convergem para oito valores ASCII", 0.78, 5.62, 4.85, { accent: C.cyan, fontSize: 10.4 });
  addBullet(slide, "leituras regressivas nao viram novo watermark", 0.78, 6.05, 4.85, { accent: C.cyan, fontSize: 10.4 });

  addSectionLabel(slide, "estados de exibicao", 6.26, 1.7, 2.8, C.teal);
  addCard(slide, { x: 6.25, y: 2.08, w: 1.92, h: 1.24, title: "in-range", body: "faixa local", accent: C.green });
  addCard(slide, { x: 8.37, y: 2.08, w: 1.92, h: 1.24, title: "low", body: "abaixo do limite", accent: C.red });
  addCard(slide, { x: 10.49, y: 2.08, w: 1.92, h: 1.24, title: "high", body: "acima do limite", accent: C.orange });
  addCard(slide, { x: 7.33, y: 3.66, w: 2.2, h: 1.35, title: "unavailable", body: "SEM DADO\nleitura vencida/ausente", accent: C.amber });
  addCard(slide, { x: 9.77, y: 3.66, w: 2.2, h: 1.35, title: "replace-sensor", body: "TROCAR\nfim previsto", accent: C.purple });
  slide.addShape(S.roundRect, {
    x: 6.25,
    y: 5.45,
    w: 6.16,
    h: 0.9,
    rectRadius: 0.06,
    fill: { color: "10283A" },
    line: { color: C.teal, width: 1, transparency: 30 },
  });
  slide.addText("Flags remotas sao metadados.\nOs limites numericos locais decidem cor e classe.", {
    x: 6.52,
    y: 5.68,
    w: 5.64,
    h: 0.44,
    fontFace: F.body,
    fontSize: 12.3,
    bold: true,
    color: C.teal,
    align: "center",
    margin: 0,
    fit: "shrink",
  });
  slide.addNotes("Destaque o contrato e os cinco estados. A classificacao nunca confia em isHigh/isLow remotos: usa limites locais. O estado carrega lifetimeMs e readingLifetimeMs, portanto validade e parte do dominio. Fontes: src/reading.mjs:31-206; src/index.mjs:572-626.");
}

// Slide 5 — ciclo principal
{
  const slide = newSlide();
  addHeader(slide, 5, "Runtime", "Um ciclo do bridge", "Polling adaptativo, cancelamento cooperativo e confirmacoes separadas.");
  const lanes = [
    { x: 1.2, title: "FONTE", color: C.purple },
    { x: 4.25, title: "CORE", color: C.teal },
    { x: 8.0, title: "TC001", color: C.green },
    { x: 11.05, title: "ESTADO LOCAL", color: C.amber },
  ];
  lanes.forEach((lane) => {
    addPill(slide, lane.title, lane.x - 0.62, 1.66, 1.58, { color: lane.color, fontSize: 8.5 });
    slide.addShape(S.line, {
      x: lane.x + 0.17,
      y: 2.05,
      w: 0,
      h: 4.25,
      line: { color: lane.color, transparency: 60, width: 1, dashType: "dash" },
    });
  });
  const step = (n, y, text, x = 4.5, w = 2.95, color = C.text) => {
    slide.addShape(S.roundRect, {
      x: x - 0.5,
      y: y - 0.03,
      w: w + 0.58,
      h: 0.38,
      rectRadius: 0.04,
      fill: { color: C.bg2 },
      line: { color: C.border, width: 0.5, transparency: 35 },
    });
    slide.addShape(S.ellipse, {
      x: x - 0.42,
      y: y + 0.01,
      w: 0.28,
      h: 0.28,
      fill: { color: C.teal },
      line: { color: C.teal, transparency: 100 },
    });
    slide.addText(String(n), {
      x: x - 0.39,
      y: y + 0.06,
      w: 0.22,
      h: 0.12,
      fontFace: F.mono,
      fontSize: 7,
      bold: true,
      color: C.bg,
      align: "center",
      margin: 0,
    });
    slide.addText(text, {
      x,
      y,
      w,
      h: 0.34,
      fontFace: F.body,
      fontSize: 9.7,
      bold: true,
      color,
      margin: 0,
      fit: "shrink",
    });
  };
  addArrow(slide, 4.4, 2.34, 1.45, 2.34, { color: C.purple, width: 1.4 });
  step(1, 2.15, "getReading + getSensorSession", 2.55, 2.25);
  slide.addText("Promise.allSettled", {
    x: 2.35,
    y: 2.58,
    w: 1.45,
    h: 0.16,
    fontFace: F.mono,
    fontSize: 7.5,
    color: C.faint,
    align: "center",
    margin: 0,
  });
  addArrow(slide, 1.45, 2.91, 4.4, 2.91, { color: C.purple, width: 1.4 });
  step(2, 2.72, "leitura + sessao (auxiliar)", 2.55, 2.25);
  step(3, 3.28, "normaliza, valida relogio e regressao", 4.55, 2.95);
  slide.addShape(S.roundRect, {
    x: 4.42,
    y: 3.66,
    w: 2.98,
    h: 0.6,
    rectRadius: 0.04,
    fill: { color: C.panel2 },
    line: { color: C.teal, width: 0.8, transparency: 35 },
  });
  slide.addText("buildDisplayState()", {
    x: 4.65,
    y: 3.84,
    w: 2.52,
    h: 0.18,
    fontFace: F.mono,
    fontSize: 10.2,
    bold: true,
    color: C.teal,
    align: "center",
    margin: 0,
  });
  addArrow(slide, 7.42, 4.52, 8.16, 4.52, { color: C.green, width: 1.6 });
  step(4, 4.33, "detectMode + push", 6.36, 1.35);
  addArrow(slide, 8.16, 5.12, 4.42, 5.12, { color: C.green, width: 1.6 });
  step(5, 4.93, "HTTP aceito", 6.42, 1.18, C.green);
  addArrow(slide, 7.75, 5.64, 11.13, 5.64, { color: C.amber, width: 1.4 });
  step(6, 5.44, "observa alarme; publica status; persiste", 6.35, 3.6);
  step(7, 6.04, "espera adaptativa + comandos IPC", 5.2, 3.35);
  slide.addShape(S.roundRect, {
    x: 9.05,
    y: 6.0,
    w: 3.55,
    h: 0.52,
    rectRadius: 0.04,
    fill: { color: "241E15" },
    line: { color: C.amber, width: 0.8, transparency: 30 },
  });
  slide.addText("backoff exponencial; teto = max(poll, 5 min), sem cruzar a validade", {
    x: 9.24,
    y: 6.16,
    w: 3.17,
    h: 0.18,
    fontFace: F.body,
    fontSize: 8.6,
    bold: true,
    color: C.amber,
    align: "center",
    margin: 0,
    fit: "shrink",
  });
  slide.addText("AbortSignal acorda rede, espera e encerramento imediatamente.", {
    x: 0.75,
    y: 6.62,
    w: 6.4,
    h: 0.25,
    fontFace: F.body,
    fontSize: 9.5,
    color: C.faint,
    italic: true,
    margin: 0,
  });
  slide.addNotes("Percorra o sequence diagram. A leitura e a sessao do sensor sao consultadas em paralelo; falha na sessao nao derruba a glicemia. O push visual e a entrega sonora sao independentes. O backoff respeita a expiracao da leitura. Fontes: src/index.mjs:733-962 e 629-650; src/http.mjs:12-49.");
}

// Slide 6 — seguranca temporal
{
  const slide = newSlide();
  addHeader(slide, 6, "Resiliencia", "Falhar sem exibir dado vencido", "Tres relogios diferentes: leitura, processo e vida util do sensor.");
  const lane = (y, label, color) => {
    slide.addText(label.toUpperCase(), {
      x: 0.7,
      y: y + 0.18,
      w: 1.52,
      h: 0.18,
      fontFace: F.body,
      fontSize: 8.3,
      bold: true,
      color,
      charSpacing: 1.1,
      margin: 0,
    });
    slide.addShape(S.line, {
      x: 2.28,
      y: y + 0.28,
      w: 10.0,
      h: 0,
      line: { color: C.border, width: 1.3 },
    });
  };
  const stateBlock = (x, y, w, text, color, sub = null) => {
    slide.addShape(S.roundRect, {
      x,
      y,
      w,
      h: 0.56,
      rectRadius: 0.04,
      fill: { color, transparency: 78 },
      line: { color, width: 1 },
    });
    slide.addText(text, {
      x: x + 0.1,
      y: y + 0.12,
      w: w - 0.2,
      h: 0.2,
      fontFace: F.body,
      fontSize: 10,
      bold: true,
      color,
      align: "center",
      margin: 0,
      fit: "shrink",
    });
    if (sub) {
      slide.addText(sub, {
        x,
        y: y + 0.62,
        w,
        h: 0.18,
        fontFace: F.body,
        fontSize: 7.7,
        color: C.faint,
        align: "center",
        margin: 0,
        fit: "shrink",
      });
    }
  };

  lane(1.88, "fonte", C.purple);
  stateBlock(2.45, 1.88, 2.15, "leitura valida", C.green, "t0");
  stateBlock(4.82, 1.88, 2.42, "fonte falha", C.orange, "ultima leitura ainda fresca");
  stateBlock(7.48, 1.88, 2.35, "deadline stale", C.red, "sem novo dado");
  stateBlock(10.08, 1.88, 2.02, "SEM DADO", C.amber, "renovado com validade");
  addArrow(slide, 4.61, 2.16, 4.78, 2.16, { color: C.faint, width: 1 });
  addArrow(slide, 7.25, 2.16, 7.44, 2.16, { color: C.faint, width: 1 });
  addArrow(slide, 9.84, 2.16, 10.04, 2.16, { color: C.faint, width: 1 });

  lane(3.35, "processo", C.cyan);
  stateBlock(2.45, 3.35, 3.05, "push confirmado", C.cyan, "payload tem lifetime");
  stateBlock(5.78, 3.35, 2.6, "bridge para", C.red, "nenhuma renovacao");
  stateBlock(8.66, 3.35, 3.44, "AWTRIX remove o app", C.green, "numero velho desaparece sozinho");
  addArrow(slide, 5.51, 3.63, 5.74, 3.63, { color: C.faint, width: 1 });
  addArrow(slide, 8.4, 3.63, 8.62, 3.63, { color: C.faint, width: 1 });

  lane(4.82, "sensor", C.purple);
  stateBlock(2.45, 4.82, 3.05, "Sensor Start / Change", C.purple, "sessao cacheada");
  stateBlock(5.78, 4.82, 2.6, "fim previsto", C.orange, "14 / 15 / custom");
  stateBlock(8.66, 4.82, 3.44, "TROCAR", C.purple, "estado distinto de SEM DADO");
  addArrow(slide, 5.51, 5.1, 5.74, 5.1, { color: C.faint, width: 1 });
  addArrow(slide, 8.4, 5.1, 8.62, 5.1, { color: C.faint, width: 1 });

  slide.addShape(S.roundRect, {
    x: 0.7,
    y: 6.12,
    w: 11.9,
    h: 0.62,
    rectRadius: 0.05,
    fill: { color: "10283A" },
    line: { color: C.teal, width: 0.9, transparency: 30 },
  });
  slide.addText("INVARIANTE  /  nenhuma falha pode prolongar a aparencia de uma leitura alem de sua validade.", {
    x: 0.98,
    y: 6.31,
    w: 11.34,
    h: 0.22,
    fontFace: F.body,
    fontSize: 11.1,
    bold: true,
    color: C.teal,
    align: "center",
    margin: 0,
    fit: "shrink",
  });
  slide.addNotes("Esta e a principal decisao de seguranca temporal. A ultima leitura pode sobreviver a uma falha momentanea, mas so ate o staleAfter. O payload no proprio TC001 expira se o PC morrer. A estimativa opcional de fim do sensor pode mostrar TROCAR, separado de SEM DADO; ela comeca desligada e requer duracao e evento de inicio confiaveis. Leitura baixa ou alta ainda valida tem prioridade sobre TROCAR. Fontes: src/reading.mjs; src/index.mjs; README.md.");
}

// Slide 7 — alarmes
{
  const slide = newSlide();
  addHeader(slide, 7, "Maquina de estados", "Alarmes sao episodios, nao eventos soltos", "Histerese, prioridade, cooldown, confirmacao e persistencia evitam tempestades e duplicidade.");
  addSectionLabel(slide, "pipeline de decisao", 0.7, 1.68, 2.5, C.orange);
  const stages = [
    ["1", "qualifica", "limites + tendencia", C.cyan],
    ["2", "episodio", "histerese + rearm", C.teal],
    ["3", "fila", "prioridade + fallback", C.orange],
    ["4", "entrega", "retry + confirmacao", C.amber],
    ["5", "snapshot", "retoma apos reinicio", C.purple],
  ];
  stages.forEach(([n, title, body, color], i) => {
    const x = 0.7 + i * 1.64;
    slide.addShape(S.roundRect, {
      x,
      y: 2.04,
      w: 1.43,
      h: 1.7,
      rectRadius: 0.06,
      fill: { color: C.panel },
      line: { color, width: 1 },
    });
    slide.addText(n, {
      x: x + 0.14,
      y: 2.2,
      w: 0.28,
      h: 0.28,
      fontFace: F.mono,
      fontSize: 14,
      bold: true,
      color,
      margin: 0,
    });
    slide.addText(title, {
      x: x + 0.14,
      y: 2.62,
      w: 1.13,
      h: 0.28,
      fontFace: F.head,
      fontSize: 12.5,
      bold: true,
      color: C.text,
      margin: 0,
      fit: "shrink",
    });
    slide.addText(body, {
      x: x + 0.14,
      y: 3.04,
      w: 1.13,
      h: 0.45,
      fontFace: F.body,
      fontSize: 8.5,
      color: C.muted,
      margin: 0,
      align: "left",
      fit: "shrink",
    });
    if (i < stages.length - 1) addArrow(slide, x + 1.45, 2.88, x + 1.6, 2.88, { color: C.faint, width: 1 });
  });

  slide.addShape(S.roundRect, {
    x: 9.18,
    y: 1.76,
    w: 3.45,
    h: 2.3,
    rectRadius: 0.08,
    fill: { color: C.bg2 },
    line: { color: C.orange, width: 1 },
  });
  addSectionLabel(slide, "prioridade", 9.47, 2.02, 1.7, C.orange);
  [["3", "LOW / HIGH", C.red], ["2", "UP / DOWN", C.orange], ["1", "SEM DADO", C.amber]].forEach(([p, label, color], i) => {
    const y = 2.42 + i * 0.48;
    slide.addShape(S.roundRect, {
      x: 9.48,
      y,
      w: 0.48,
      h: 0.34,
      rectRadius: 0.04,
      fill: { color, transparency: 5 },
      line: { color, transparency: 100 },
    });
    slide.addText(p, {
      x: 9.61,
      y: y + 0.07,
      w: 0.2,
      h: 0.14,
      fontFace: F.mono,
      fontSize: 8,
      bold: true,
      color: C.bg,
      align: "center",
      margin: 0,
    });
    slide.addText(label, {
      x: 10.17,
      y: y + 0.07,
      w: 1.92,
      h: 0.16,
      fontFace: F.body,
      fontSize: 9.6,
      bold: true,
      color,
      margin: 0,
    });
  });

  addMetric(slide, "5 mg/dL", "histerese padrao", 0.7, 4.43, 2.2, { accent: C.cyan });
  addMetric(slide, "5 min", "cooldown padrao", 3.03, 4.43, 2.2, { accent: C.teal });
  addMetric(slide, "3 x 30 s", "rajada de entrega", 5.36, 4.43, 2.2, { accent: C.orange });
  addMetric(slide, "v1", "snapshot + fingerprint", 7.69, 4.43, 2.2, { accent: C.purple });
  addMetric(slide, "OFF", "alarme em instalacao nova", 10.02, 4.43, 2.6, { accent: C.amber });

  slide.addShape(S.roundRect, {
    x: 0.7,
    y: 5.76,
    w: 11.92,
    h: 0.82,
    rectRadius: 0.05,
    fill: { color: C.panel },
    line: { color: C.border, width: 0.9 },
  });
  slide.addText("pending", { x: 0.98, y: 6.04, w: 0.8, h: 0.18, fontFace: F.mono, fontSize: 10, bold: true, color: C.orange, margin: 0 });
  addArrow(slide, 1.88, 6.13, 2.45, 6.13, { color: C.faint, width: 1 });
  slide.addText("confirmed", { x: 2.58, y: 6.04, w: 0.98, h: 0.18, fontFace: F.mono, fontSize: 10, bold: true, color: C.green, margin: 0 });
  slide.addText("ou", { x: 3.73, y: 6.04, w: 0.28, h: 0.18, fontFace: F.body, fontSize: 9, color: C.faint, margin: 0 });
  slide.addText("burst exhausted", { x: 4.15, y: 6.04, w: 1.55, h: 0.18, fontFace: F.mono, fontSize: 10, bold: true, color: C.red, margin: 0 });
  addArrow(slide, 5.78, 6.13, 6.35, 6.13, { color: C.faint, width: 1 });
  slide.addText("pausa maior; episodio continua pendente se ainda valer", {
    x: 6.51,
    y: 6.03,
    w: 5.62,
    h: 0.22,
    fontFace: F.body,
    fontSize: 10,
    color: C.muted,
    margin: 0,
    fit: "shrink",
  });
  slide.addNotes("Mostre que o tracker modela episodios. Prioridade de limite vence tendencia; tendencia vence indisponibilidade. Fila e fallbacks preservam alertas concorrentes. A resposta do TC001 confirma entrega do comando, nao som fisico. Defaults sao configuraveis; o master switch vem desligado. Fontes: src/glucose-alarm.mjs; src/index.mjs:194-257; README.md:88-128.");
}

// Slide 8 — protocolos AWTRIX
{
  const slide = newSlide();
  addHeader(slide, 8, "Adapters", "Um cliente, dois protocolos AWTRIX", "Detecção automática esconde diferenças de endpoint, payload, tempo e áudio.");
  addCard(slide, {
    x: 0.7,
    y: 1.7,
    w: 5.86,
    h: 4.72,
    label: "preferido para novas instalacoes",
    title: "AWTRIX NG",
    body: null,
    accent: C.cyan,
  });
  addMiniLed(slide, 4.82, 2.08, 1.2, C.green);
  const ng = [
    ["detect", "GET /api/v1/version"],
    ["push", "PUT /api/v1/apps/pushed/{name}"],
    ["render", "draw: pixels  /  lifetimeMs"],
    ["áudio", "POST /api/v1/audio/play"],
    ["buzzer", "capabilities + PATCH settings"],
  ];
  ng.forEach(([k, v], i) => {
    const y = 2.75 + i * 0.58;
    addPill(slide, k.toUpperCase(), 1.02, y, 0.82, { color: C.cyan, fontSize: 7.2 });
    slide.addText(v, {
      x: 2.03,
      y: y + 0.07,
      w: 3.95,
      h: 0.2,
      fontFace: F.mono,
      fontSize: 9.5,
      color: C.text,
      margin: 0,
      fit: "shrink",
    });
  });

  addCard(slide, {
    x: 6.77,
    y: 1.7,
    w: 5.86,
    h: 4.72,
    label: "compatibilidade legada",
    title: "AWTRIX 3",
    body: null,
    accent: C.amber,
  });
  addMiniLed(slide, 10.88, 2.08, 1.2, C.amber);
  const legacy = [
    ["detect", "GET /api/stats"],
    ["push", "POST /api/custom?name=..."],
    ["render", "text  /  lifetime em segundos"],
    ["áudio", "POST /api/rtttl"],
    ["persist", "save: false"],
  ];
  legacy.forEach(([k, v], i) => {
    const y = 2.75 + i * 0.58;
    addPill(slide, k.toUpperCase(), 7.08, y, 0.82, { color: C.amber, fontSize: 7.2 });
    slide.addText(v, {
      x: 8.09,
      y: y + 0.07,
      w: 3.95,
      h: 0.2,
      fontFace: F.mono,
      fontSize: 9.5,
      color: C.text,
      margin: 0,
      fit: "shrink",
    });
  });
  slide.addShape(S.roundRect, {
    x: 1.35,
    y: 5.87,
    w: 10.62,
    h: 0.74,
    rectRadius: 0.05,
    fill: { color: "10283A" },
    line: { color: C.teal, width: 0.8, transparency: 35 },
  });
  slide.addText("COMUM  /  Basic Auth opcional  •  segredo da fonte nunca entra no payload  •  app sempre expira", {
    x: 1.64,
    y: 6.1,
    w: 10.05,
    h: 0.2,
    fontFace: F.body,
    fontSize: 10.4,
    bold: true,
    color: C.teal,
    align: "center",
    margin: 0,
    fit: "shrink",
  });
  slide.addNotes("Compare os dois adaptadores. NG desenha pixels numa matriz 32x8 e usa milissegundos; o legado recebe texto e segundos. O controle seguro do buzzer so e exposto no NG quando capabilities anuncia o hardware. Fontes: src/awtrix-client.mjs:140-437; README.md:11-21.");
}

// Slide 9 — Windows e configuracao transacional
{
  const slide = newSlide();
  addHeader(slide, 9, "Control plane", "Desktop Windows sem Electron", "WinForms hospeda a experiencia; o bridge Node roda como processo separado e reiniciavel.");
  addSectionLabel(slide, "cadeia de inicializacao", 0.68, 1.66, 2.8, C.cyan);
  const boot = [
    ["atalho", C.faint],
    ["wscript + VBS", C.cyan],
    ["PowerShell STA", C.purple],
    ["tray / supervisor", C.teal],
    ["node index.mjs", C.green],
  ];
  boot.forEach(([t, color], i) => {
    const y = 2.02 + i * 0.65;
    addPill(slide, t, 0.72, y, 2.25, { color, fontSize: 8.5 });
    if (i < boot.length - 1) addArrow(slide, 1.84, y + 0.36, 1.84, y + 0.6, { color: C.faint, width: 1 });
  });

  slide.addShape(S.roundRect, {
    x: 3.28,
    y: 1.92,
    w: 4.35,
    h: 2.02,
    rectRadius: 0.07,
    fill: { color: C.panel },
    line: { color: C.border, width: 1 },
  });
  addSectionLabel(slide, "ipc local por arquivos", 3.58, 2.18, 2.8, C.amber);
  addPill(slide, "status.json v2", 3.58, 2.62, 1.2, { color: C.cyan, fontSize: 7.6 });
  addPill(slide, "command.json", 4.94, 2.62, 1.18, { color: C.orange, fontSize: 7.6 });
  addPill(slide, "stop.json", 6.28, 2.62, 0.98, { color: C.red, fontSize: 7.6 });
  slide.addText("GUID de instancia + requestId + prazo; claim atomico por rename.", {
    x: 3.58,
    y: 3.19,
    w: 3.7,
    h: 0.38,
    fontFace: F.body,
    fontSize: 9.8,
    color: C.muted,
    align: "center",
    margin: 0,
    fit: "shrink",
  });

  if (fs.existsSync(SCREENSHOT)) {
    slide.addShape(S.roundRect, {
      x: 8.1,
      y: 1.67,
      w: 4.64,
      h: 3.82,
      rectRadius: 0.06,
      fill: { color: C.panel },
      line: { color: C.border, width: 1 },
    });
    slide.addImage({
      path: SCREENSHOT,
      altText: "Revisao do assistente com dados de demonstracao",
      x: 8.22,
      y: 1.8,
      w: 4.4,
      h: 3.47,
    });
    slide.addText("Wizard WinForms — revisao sem exibir segredos", {
      x: 8.22,
      y: 5.31,
      w: 4.4,
      h: 0.18,
      fontFace: F.body,
      fontSize: 8,
      color: C.faint,
      align: "center",
      margin: 0,
    });
  }

  slide.addShape(S.roundRect, {
    x: 0.7,
    y: 5.73,
    w: 11.93,
    h: 0.88,
    rectRadius: 0.05,
    fill: { color: C.bg2 },
    line: { color: C.teal, width: 1, transparency: 25 },
  });
  addSectionLabel(slide, "commit de configuracao", 0.97, 5.96, 2.3, C.teal);
  const tx = ["allowlist", "validar", "revisao + lock", "snapshot", "temp + rename", "reler + reiniciar bridge"];
  tx.forEach((t, i) => {
    const x = 3.02 + i * 1.48;
    addPill(slide, t, x, 5.94, 1.25, { color: i === tx.length - 1 ? C.green : C.teal, fontSize: 6.8 });
    if (i < tx.length - 1) addArrow(slide, x + 1.26, 6.11, x + 1.43, 6.11, { color: C.faint, width: 0.8 });
  });
  slide.addNotes("A cadeia real e atalho -> wscript/VBS -> PowerShell STA oculto -> tray -> iniciar.ps1 -> Node. Mutex por SID evita duplicacao. O IPC por arquivos e simples, auditavel e suficiente para maquina unica. A configuracao usa allowlist, revisao SHA-256, lock, snapshot, escrita atomica, verificacao e reinicio somente do bridge. Fontes: installer/iniciar-instalado.*; scripts/iniciar-bandeja.ps1; src/config-editor*.mjs; src/config-history.mjs.");
}

// Slide 10 — seguranca e cadeia de release
{
  const slide = newSlide();
  addHeader(slide, 10, "Trust boundaries", "Seguranca e privacidade por desenho", "Minimizacao de dados no runtime; cadeia de confianca explicita para releases.");
  addSectionLabel(slide, "fluxo de dados", 0.7, 1.67, 2.1, C.teal);
  addCard(slide, { x: 0.7, y: 2.03, w: 2.42, h: 1.55, title: "Fonte remota", body: "HTTPS obrigatorio\nHTTP so em loopback", accent: C.purple });
  addCard(slide, { x: 4.1, y: 1.83, w: 4.05, h: 1.98, title: "PC / trust boundary", body: "DPAPI por usuario • redirects manuais\nsanitizacao dupla • escrita atomica", accent: C.teal });
  addCard(slide, { x: 9.1, y: 2.03, w: 3.08, h: 1.55, title: "TC001 na LAN", body: "valor + estado\nHTTP / Basic Auth opcional", accent: C.green });
  addArrow(slide, 3.14, 2.8, 4.02, 2.8, { color: C.cyan, width: 1.8 });
  addArrow(slide, 8.17, 2.8, 9.02, 2.8, { color: C.green, width: 1.8 });
  addPill(slide, "SEGREDOS NAO CRUZAM", 5.19, 3.32, 1.88, { color: C.teal, fontSize: 7.2 });
  slide.addShape(S.roundRect, {
    x: 0.7,
    y: 4.18,
    w: 11.5,
    h: 1.56,
    rectRadius: 0.07,
    fill: { color: C.panel },
    line: { color: C.border, width: 1 },
  });
  addSectionLabel(slide, "pipeline de release / update", 0.98, 4.43, 3.1, C.cyan);
  const release = [
    ["allowlist", C.green, "feito"],
    ["ZIP + SHA-256", C.green, "feito"],
    ["Inno Setup", C.green, "feito"],
    ["Authenticode", C.amber, "pendente"],
    ["feed HTTPS + pins", C.amber, "pendente"],
    ["confirmacao humana", C.green, "feito"],
  ];
  release.forEach(([label, color, status], i) => {
    const x = 1.0 + i * 1.82;
    slide.addShape(S.roundRect, {
      x,
      y: 4.84,
      w: 1.5,
      h: 0.54,
      rectRadius: 0.04,
      fill: { color, transparency: 82 },
      line: { color, width: 0.9 },
    });
    slide.addText(label, {
      x: x + 0.08,
      y: 4.95,
      w: 1.34,
      h: 0.18,
      fontFace: F.body,
      fontSize: 8.2,
      bold: true,
      color,
      align: "center",
      margin: 0,
      fit: "shrink",
    });
    slide.addText(status.toUpperCase(), {
      x,
      y: 5.43,
      w: 1.5,
      h: 0.13,
      fontFace: F.body,
      fontSize: 6.4,
      bold: true,
      color,
      align: "center",
      charSpacing: 0.8,
      margin: 0,
    });
    if (i < release.length - 1) addArrow(slide, x + 1.52, 5.11, x + 1.78, 5.11, { color: C.faint, width: 0.8 });
  });
  slide.addShape(S.roundRect, {
    x: 0.7,
    y: 6.06,
    w: 11.5,
    h: 0.65,
    rectRadius: 0.05,
    fill: { color: "2A2114" },
    line: { color: C.amber, width: 0.9, transparency: 20 },
  });
  slide.addText("LIMITE HONESTO  /  HTTP do AWTRIX nao cifra a LAN. Basic Auth autentica; nao e TLS. Segmentar a rede continua importante.", {
    x: 0.96,
    y: 6.26,
    w: 10.98,
    h: 0.22,
    fontFace: F.body,
    fontSize: 10.1,
    bold: true,
    color: C.amber,
    align: "center",
    margin: 0,
    fit: "shrink",
  });
  slide.addNotes("Separe runtime e supply chain. Fontes remotas exigem HTTPS; redirect e manual para nao vazar autenticacao. Segredos ficam no DPAPI; logs e diagnósticos removem credenciais e glicemia. O updater ja modela HTTPS, limites, SHA-256, publisher pin e Authenticode na UI, mas a release local atual esta sem assinatura e sem feed real. Fontes: src/config.mjs:64-115; src/http.mjs; PRIVACY.md; src/update-manager.mjs; scripts/manutencao-ui.ps1; release/artifacts/0.1.0/artifact-manifest.json; PUBLICACAO.md:218-227.");
}

// Slide 11 — observabilidade
{
  const slide = newSlide();
  addHeader(slide, 11, "Operabilidade", "Processo vivo nao significa sistema saudavel", "Status v2 separa cada elo para localizar causa, sintoma e confirmacao.");
  const health = [
    ["bridge", "instancia / ciclo", C.teal],
    ["source", "tentativa / sucesso", C.purple],
    ["clock", "offset / coerencia", C.cyan],
    ["reading", "timestamp / expiry", C.green],
    ["tc001", "push confirmado", C.orange],
    ["sound", "alarme automatico", C.red],
    ["deviceSound", "buzzer conhecido", C.amber],
  ];
  health.forEach(([title, sub, color], i) => {
    const x = 0.68 + i * 1.78;
    slide.addShape(S.roundRect, {
      x,
      y: 1.8,
      w: 1.56,
      h: 1.28,
      rectRadius: 0.06,
      fill: { color: C.panel },
      line: { color, width: 1 },
    });
    slide.addShape(S.ellipse, {
      x: x + 0.18,
      y: 2.04,
      w: 0.16,
      h: 0.16,
      fill: { color },
      line: { color, transparency: 100 },
    });
    slide.addText(title, {
      x: x + 0.18,
      y: 2.34,
      w: 1.18,
      h: 0.22,
      fontFace: F.mono,
      fontSize: 9.4,
      bold: true,
      color,
      margin: 0,
      fit: "shrink",
    });
    slide.addText(sub, {
      x: x + 0.18,
      y: 2.7,
      w: 1.18,
      h: 0.2,
      fontFace: F.body,
      fontSize: 7.7,
      color: C.muted,
      margin: 0,
      fit: "shrink",
    });
  });
  slide.addShape(S.roundRect, {
    x: 0.7,
    y: 3.48,
    w: 11.9,
    h: 0.92,
    rectRadius: 0.05,
    fill: { color: "10283A" },
    line: { color: C.cyan, width: 1, transparency: 35 },
  });
  slide.addText("processo vivo  !=  fonte saudavel  !=  leitura atual  !=  push confirmado  !=  som fisicamente ouvido", {
    x: 1.0,
    y: 3.76,
    w: 11.3,
    h: 0.28,
    fontFace: F.mono,
    fontSize: 13.4,
    bold: true,
    color: C.cyan,
    align: "center",
    margin: 0,
    fit: "shrink",
  });
  addCard(slide, {
    x: 0.7,
    y: 4.82,
    w: 3.7,
    h: 1.45,
    title: "Logs tolerantes",
    body: "rotacao 1 MiB x 5; falha de disco nao derruba o bridge",
    accent: C.teal,
  });
  addCard(slide, {
    x: 4.8,
    y: 4.82,
    w: 3.7,
    h: 1.45,
    title: "Diagnostico higienizado",
    body: "segunda sanitizacao; cauda limitada; escrita atomica",
    accent: C.purple,
  });
  addCard(slide, {
    x: 8.9,
    y: 4.82,
    w: 3.7,
    h: 1.45,
    title: "Teste fisico assistido",
    body: "HTTP aceito nao prova LED/piezo; usuario confirma o que viu e ouviu",
    accent: C.amber,
  });
  slide.addNotes("Esta separacao e um ponto forte. O status sintetico nao mascara falha do TC001 nem confunde bridge rodando com leitura entregue. Diagnostico aplica sanitizacao novamente. O teste completo pede confirmacao humana porque software nao consegue provar o efeito fisico do LED/piezo. Fontes: src/runtime-status.mjs; src/logger.mjs; src/support-diagnostics.mjs; README.md:131-145.");
}

// Slide 12 — qualidade e maturidade
{
  const slide = newSlide();
  addHeader(slide, 12, "Evidencia", "Qualidade verificavel — e o limite dessa evidencia", "Resultados locais em 30/08/2026; cobertura refere-se apenas aos modulos Node carregados.");
  addMetric(slide, "258 / 258", "testes passaram", 0.7, 1.72, 1.75, { accent: C.green });
  addMetric(slide, "29", "arquivos de teste", 2.6, 1.72, 1.3, { accent: C.cyan });
  addMetric(slide, "5,35 s", "tempo da suite", 4.05, 1.72, 1.3, { accent: C.teal });
  addMetric(slide, "0", "deps npm runtime", 5.5, 1.72, 1.3, { accent: C.purple });

  addSectionLabel(slide, "cobertura node / 23 modulos carregados", 0.72, 3.08, 4.4, C.cyan);
  addCoverageBar(slide, "linhas", 89.82, 3.5, C.green);
  addCoverageBar(slide, "branches", 78.87, 4.02, C.amber);
  addCoverageBar(slide, "funcoes", 86.77, 4.54, C.cyan);
  slide.addText("Nao inclui PowerShell, instalador e dois CLIs Node nao carregados.", {
    x: 0.84,
    y: 5.04,
    w: 5.55,
    h: 0.32,
    fontFace: F.body,
    fontSize: 9.2,
    color: C.faint,
    italic: true,
    margin: 0,
  });

  slide.addShape(S.roundRect, {
    x: 7.02,
    y: 1.72,
    w: 5.6,
    h: 4.96,
    rectRadius: 0.08,
    fill: { color: C.panel },
    line: { color: C.border, width: 1 },
  });
  addSectionLabel(slide, "o que a suite prova", 7.34, 2.0, 2.8, C.green);
  const rows = [
    ["Dominio / alarmes / AWTRIX", "FORTE", C.green],
    ["Integracao local + subprocessos", "BOA", C.teal],
    ["UI PowerShell", "PARCIAL / CONTRATO", C.amber],
    ["TC001 / Nightscout reais", "SEM HIL", C.red],
    ["VM limpa + Authenticode real", "PENDENTE", C.red],
  ];
  rows.forEach(([label, status, color], i) => {
    const y = 2.48 + i * 0.62;
    slide.addText(label, {
      x: 7.36,
      y: y + 0.06,
      w: 2.72,
      h: 0.2,
      fontFace: F.body,
      fontSize: 9.4,
      color: C.text,
      margin: 0,
      fit: "shrink",
    });
    addPill(slide, status, 10.28, y, 1.92, { color, fontSize: 7.2 });
    if (i < rows.length - 1) {
      slide.addShape(S.line, {
        x: 7.35,
        y: y + 0.48,
        w: 4.85,
        h: 0,
        line: { color: C.border, width: 0.5 },
      });
    }
  });
  slide.addShape(S.roundRect, {
    x: 7.34,
    y: 5.76,
    w: 4.86,
    h: 0.6,
    rectRadius: 0.04,
    fill: { color: "2A1720" },
    line: { color: C.red, width: 0.8, transparency: 25 },
  });
  slide.addText("Release local: EXE sem assinatura; feed real ainda nao configurado.", {
    x: 7.58,
    y: 5.95,
    w: 4.38,
    h: 0.2,
    fontFace: F.body,
    fontSize: 9,
    bold: true,
    color: C.red,
    align: "center",
    margin: 0,
    fit: "shrink",
  });
  slide.addText("Leitura importante: cobertura Node != cobertura do produto inteiro.", {
    x: 0.7,
    y: 6.3,
    w: 5.85,
    h: 0.28,
    fontFace: F.body,
    fontSize: 11.2,
    bold: true,
    color: C.amber,
    margin: 0,
  });
  slide.addNotes("Resultados verificados nesta maquina: npm.cmd test, 258/258 em cerca de 5,35 s. A cobertura experimental do Node foi 89,82% linhas, 78,87% branches e 86,77% funcoes em 23 modulos carregados. Isso nao cobre PowerShell, instalador, hardware real nem VM limpa. A lacuna mais clara e sources/json.mjs. A release local atual esta sem assinatura e sem feed real. Fontes: test/; package.json; release/artifacts/0.1.0/artifact-manifest.json; PUBLICACAO.md.");
}

// Slide 13 — avaliacao e proximos passos
{
  const slide = newSlide();
  addHeader(slide, 13, "Conclusao", "Engenharia cuidadosa; produto ainda em pre-publicacao", "O nucleo resolve bem o problema local. A confianca publica depende agora de processo e evidencia externa.");
  addCard(slide, {
    x: 0.7,
    y: 1.72,
    w: 5.7,
    h: 3.55,
    label: "o que esta bem resolvido",
    title: "Pontos fortes",
    body: null,
    accent: C.green,
  });
  addBullet(slide, "dominio temporal explicito: stale, lifetime e TROCAR", 1.02, 2.55, 4.95, { accent: C.green, fontSize: 10.4 });
  addBullet(slide, "ports & adapters simples, sem framework nem deps runtime", 1.02, 3.02, 4.95, { accent: C.green, fontSize: 10.4 });
  addBullet(slide, "alarmes persistentes com prioridade e confirmacao", 1.02, 3.49, 4.95, { accent: C.green, fontSize: 10.4 });
  addBullet(slide, "configuracao transacional e recuperacao defensiva", 1.02, 3.96, 4.95, { accent: C.green, fontSize: 10.4 });
  addBullet(slide, "observabilidade e sanitizacao acima da media", 1.02, 4.43, 4.95, { accent: C.green, fontSize: 10.4 });

  addCard(slide, {
    x: 6.68,
    y: 1.72,
    w: 5.95,
    h: 3.55,
    label: "custos assumidos",
    title: "Trade-offs",
    body: null,
    accent: C.amber,
  });
  addBullet(slide, "Windows-only; sessao aberta e PC ligado", 7.0, 2.55, 5.1, { accent: C.amber, fontSize: 10.4 });
  addBullet(slide, "IPC por filesystem e interfaces JS implicitas", 7.0, 3.02, 5.1, { accent: C.amber, fontSize: 10.4 });
  addBullet(slide, "loop central e UI PowerShell concentram complexidade", 7.0, 3.49, 5.1, { accent: C.amber, fontSize: 10.4 });
  addBullet(slide, "fonte intermediaria: Nightscout ou JSON autorizado", 7.0, 3.96, 5.1, { accent: C.amber, fontSize: 10.4 });
  addBullet(slide, "HTTP do TC001 e limite de seguranca da LAN", 7.0, 4.43, 5.1, { accent: C.amber, fontSize: 10.4 });

  slide.addShape(S.roundRect, {
    x: 0.7,
    y: 5.62,
    w: 11.93,
    h: 0.92,
    rectRadius: 0.06,
    fill: { color: C.bg2 },
    line: { color: C.teal, width: 1 },
  });
  addSectionLabel(slide, "proximos passos prioritarios", 0.98, 5.88, 3.2, C.teal);
  const next = [
    ["1", "CI + lint + gate de cobertura"],
    ["2", "testes JSON + HIL / VM limpa"],
    ["3", "decompor hotspots PowerShell"],
    ["4", "assinar + publicar feed/pins"],
  ];
  next.forEach(([n, text], i) => {
    const x = 3.55 + i * 2.18;
    slide.addShape(S.ellipse, {
      x,
      y: 5.88,
      w: 0.32,
      h: 0.32,
      fill: { color: C.teal },
      line: { color: C.teal, transparency: 100 },
    });
    slide.addText(n, {
      x: x + 0.07,
      y: 5.95,
      w: 0.18,
      h: 0.12,
      fontFace: F.mono,
      fontSize: 7,
      bold: true,
      color: C.bg,
      align: "center",
      margin: 0,
    });
    slide.addText(text, {
      x: x + 0.42,
      y: 5.88,
      w: 1.65,
      h: 0.34,
      fontFace: F.body,
      fontSize: 8.5,
      bold: true,
      color: C.text,
      margin: 0,
      fit: "shrink",
    });
  });
  slide.addText("Resumo: uma bridge local bem pensada — nunca um alarme medico autonomo.", {
    x: 0.72,
    y: 6.72,
    w: 11.88,
    h: 0.27,
    fontFace: F.head,
    fontSize: 15,
    bold: true,
    color: C.teal,
    align: "center",
    margin: 0,
  });
  slide.addNotes("Feche de forma honesta: o nucleo mostra cuidado de engenharia, especialmente em tempo, estado, privacidade e recuperacao. Para publicacao confiavel faltam assinatura real, feed/pins, CI, HIL e validacao em VM limpa. Nunca venda como alarme medico autonomo. Arquivos para continuar a conversa: src/index.mjs, src/reading.mjs, src/glucose-alarm.mjs, src/awtrix-client.mjs, src/runtime-status.mjs, scripts/iniciar-bandeja.ps1 e PUBLICACAO.md.");
}

// Propriedades finais e gravacao.
pptx.writeFile({ fileName: OUT, compression: true })
  .then(() => {
    process.stdout.write(`${OUT}\n`);
  })
  .catch((error) => {
    process.stderr.write(`${error?.stack || error}\n`);
    process.exitCode = 1;
  });
