// §i18n The mail, in the language the player chose (profiles.language, 0023).
//
// The web app has its own dictionaries; these are only the strings that go out by email. Same
// rule as there: `tr` and `bg` are typed against `en`, so a missing key fails the deploy. Team,
// player, competition and crew names are passed through exactly as the provider or the player
// wrote them. A player who has never chosen falls back to English.

export type Lang = "en" | "tr" | "bg";
export const isLang = (v: unknown): v is Lang => v === "en" || v === "tr" || v === "bg";
export const langOf = (v: unknown): Lang => (isLang(v) ? v : "en");

// Each language reads its times where its players live, and says so.
const ZONES: Record<Lang, string> = { en: "Europe/London", tr: "Europe/Istanbul", bg: "Europe/Sofia" };
const LOCALES: Record<Lang, string> = { en: "en-GB", tr: "tr-TR", bg: "bg-BG" };

export const kickoff = (iso: string, lang: Lang) =>
  new Date(iso).toLocaleString(LOCALES[lang], {
    weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit",
    hourCycle: "h23", timeZone: ZONES[lang],
  });

export const dayOf = (iso: string, lang: Lang) =>
  new Date(iso).toLocaleDateString(LOCALES[lang], { weekday: "short", day: "numeric", month: "short", timeZone: ZONES[lang] });

export const num = (n: unknown, lang: Lang) =>
  Number(n ?? 0).toLocaleString(LOCALES[lang], { maximumFractionDigits: 2 });

const en = {
  tz: "UK time",
  footerPre: "You get this because it is switched on in ",
  footerLink: "settings",
  footerPost: ". Every mail is switchable.",
  someone: "Someone",
  there: "there",
  markets: {
    winner: "the result", total: "the total", spread: "the handicap", score: "the exact scoreline",
    draw: "the draw", motm: "best on the pitch", scorer: "a goalscorer", assist: "the assist",
    yellow: "the yellow card", red: "the red card",
  } as Record<string, string>,
  newCard: {
    subject: (tie: string) => `Card open: ${tie}`,
    opened: (who: string, kind: string, where: string) => `${who} opened a ${kind} ${where}.`,
    complex: (n: number) => `complex card · ${n} calls`,
    simple: (n: number) => `simple card · ${n} calls`,
    inCrew: (crew: string) => `in ${crew}`,
    openBoard: "on the open board",
    when: (comp: string, when: string, tz: string) => `${comp} · kicks off ${when} ${tz}. The card locks at kick-off.`,
    cta: "Fill the card",
  },
  deadline: {
    subject: (tie: string) => `One hour: ${tie}`,
    title: "One hour to the lock",
    locks: (tie: string, when: string, tz: string) => `${tie} locks at ${when} ${tz}.`,
    blanks: (list: string) => `Still blank: ${list}.`,
    notStarted: "You have not started your card yet.",
    cta: "Finish the card",
  },
  crew: {
    subject: (crew: string, n: number) => `${crew}: ${n} new in the crew room`,
    receipt: (who: string, call: string, points: string) => `${who} — receipt: called ${call} ${points}`,
    cta: "Open the crew room",
  },
  result: {
    subject: (home: string, hs: number, as: number, away: string, fix: boolean) =>
      `${fix ? "Correction: " : ""}${home} ${hs} – ${as} ${away}`,
    fullTime: (name: string) => `Full time, ${name}. `,
    corrected: (from: string, to: string) =>
      `The provider corrected this match after settlement, so it has been re-scored and your balance adjusted. This card moved from ${from} to ${to}.<br><br>`,
    yourCard: (crew: string, staked: string, hits: number, of: number, list: string, net: string) =>
      `Your card${crew}: ${staked} staked, ${hits} of ${of} landed (${list}) — ${net} on the card.`,
    inCrew: (crew: string) => ` in ${crew}`,
    up: (n: string) => `up ${n}`,
    down: (n: string) => `down ${n}`,
    level: "level",
    nothingLanded: "nothing landed",
    hold: (points: string) => `<br>You hold ${points}.`,
    points: (n: string) => `${n} points`,
    overall: (pos: string) => ` You are ${pos} overall.`,
    ordinal: (i: number) => { const s = ["th", "st", "nd", "rd"], v = i % 100; return i + (s[(v - 20) % 10] || s[v] || s[0]); },
    cta: "See the recap",
  },
  digest: {
    subject: "Your Friday crew card",
    title: "The week ahead",
    fixtures: "Fixtures",
    quiet: "Quiet week.",
    yourCrews: "Your crews",
    noCrews: "No crews yet — make one and invite the group chat.",
    crewLine: (crew: string, points: string) => `<b>${crew}</b> — ${points} pts`,
    rival: (score: string) => ` · crew v crew ${score}`,
    playing: (n: string) => ` · ${n} playing`,
    cta: "Open the board",
  },
};

export type Mail = typeof en;

const tr: Mail = {
  tz: "İstanbul saatiyle",
  footerPre: "Bu maili alıyorsun çünkü ",
  footerLink: "ayarlarında",
  footerPost: " açık. Her mail kapatılabilir.",
  someone: "Biri",
  there: "merhaba",
  markets: {
    winner: "maç sonucu", total: "alt-üst", spread: "handikap", score: "kesin skor",
    draw: "beraberlik", motm: "maçın adamı", scorer: "golcü", assist: "asist",
    yellow: "sarı kart", red: "kırmızı kart",
  } as Record<string, string>,
  newCard: {
    subject: (tie: string) => `Kupon açıldı: ${tie}`,
    opened: (who: string, kind: string, where: string) => `${who}, ${where} bir ${kind} açtı.`,
    complex: (n: number) => `geniş kupon · ${n} tahmin`,
    simple: (n: number) => `basit kupon · ${n} tahmin`,
    inCrew: (crew: string) => `${crew} ekibinde`,
    openBoard: "açık tabelada",
    when: (comp: string, when: string, tz: string) => `${comp} · başlama ${when} (${tz}). Kupon maç başlarken kilitlenir.`,
    cta: "Kuponu doldur",
  },
  deadline: {
    subject: (tie: string) => `Bir saat kaldı: ${tie}`,
    title: "Kilide bir saat",
    locks: (tie: string, when: string, tz: string) => `${tie} maçı ${when} (${tz}) kilitleniyor.`,
    blanks: (list: string) => `Hâlâ boş: ${list}.`,
    notStarted: "Kuponuna henüz başlamadın.",
    cta: "Kuponu bitir",
  },
  crew: {
    subject: (crew: string, n: number) => `${crew}: odada ${n} yeni mesaj`,
    receipt: (who: string, call: string, points: string) => `${who} — fiş: ${call} dedi ${points}`,
    cta: "Ekip odasını aç",
  },
  result: {
    subject: (home: string, hs: number, as: number, away: string, fix: boolean) =>
      `${fix ? "Düzeltme: " : ""}${home} ${hs} – ${as} ${away}`,
    fullTime: (name: string) => `Maç sonu, ${name}. `,
    corrected: (from: string, to: string) =>
      `Sağlayıcı bu maçı sonuçlandıktan sonra düzeltti; maç yeniden puanlandı ve bakiyen güncellendi. Bu kupon ${from} puandan ${to} puana geçti.<br><br>`,
    yourCard: (crew: string, staked: string, hits: number, of: number, list: string, net: string) =>
      `Kuponun${crew}: ${staked} yatırıldı, ${of} tahminin ${hits} tanesi tuttu (${list}) — kuponda ${net}.`,
    inCrew: (crew: string) => ` (${crew})`,
    up: (n: string) => `${n} kârda`,
    down: (n: string) => `${n} zararda`,
    level: "başa baş",
    nothingLanded: "hiçbiri tutmadı",
    hold: (points: string) => `<br>Elinde ${points} var.`,
    points: (n: string) => `${n} puan`,
    overall: (pos: string) => ` Genel sıralamada ${pos} sıradasın.`,
    ordinal: (i: number) => `${i}.`,
    cta: "Özeti gör",
  },
  digest: {
    subject: "Cuma ekip kartın",
    title: "Önümüzdeki hafta",
    fixtures: "Maçlar",
    quiet: "Sakin bir hafta.",
    yourCrews: "Ekiplerin",
    noCrews: "Henüz ekip yok — bir tane kur ve grup sohbetini davet et.",
    crewLine: (crew: string, points: string) => `<b>${crew}</b> — ${points} puan`,
    rival: (score: string) => ` · ekip ekibe ${score}`,
    playing: (n: string) => ` · ${n} kişi oynuyor`,
    cta: "Tabelayı aç",
  },
};

const bg: Mail = {
  tz: "българско време",
  footerPre: "Получаваш това, защото е включено в ",
  footerLink: "настройките",
  footerPost: ". Всеки имейл може да се изключи.",
  someone: "Някой",
  there: "здравей",
  markets: {
    winner: "крайния резултат", total: "над/под", spread: "хандикапа", score: "точния резултат",
    draw: "равния", motm: "играч на мача", scorer: "голмайстора", assist: "асистенцията",
    yellow: "жълтия картон", red: "червения картон",
  } as Record<string, string>,
  newCard: {
    subject: (tie: string) => `Отворен фиш: ${tie}`,
    opened: (who: string, kind: string, where: string) => `${who} отвори ${kind} ${where}.`,
    complex: (n: number) => `пълен фиш · ${n} прогнози`,
    simple: (n: number) => `прост фиш · ${n} прогнози`,
    inCrew: (crew: string) => `в ${crew}`,
    openBoard: "на публичното табло",
    when: (comp: string, when: string, tz: string) => `${comp} · начало ${when} ${tz}. Фишът се заключва в началото на мача.`,
    cta: "Попълни фиша",
  },
  deadline: {
    subject: (tie: string) => `Един час: ${tie}`,
    title: "Един час до заключването",
    locks: (tie: string, when: string, tz: string) => `${tie} се заключва в ${when} ${tz}.`,
    blanks: (list: string) => `Още празни: ${list}.`,
    notStarted: "Още не си започнал фиша си.",
    cta: "Довърши фиша",
  },
  crew: {
    subject: (crew: string, n: number) => `${crew}: ${n} нови в стаята`,
    receipt: (who: string, call: string, points: string) => `${who} — бележка: позна ${call} ${points}`,
    cta: "Отвори стаята на екипа",
  },
  result: {
    subject: (home: string, hs: number, as: number, away: string, fix: boolean) =>
      `${fix ? "Корекция: " : ""}${home} ${hs} – ${as} ${away}`,
    fullTime: (name: string) => `Край на мача, ${name}. `,
    corrected: (from: string, to: string) =>
      `Доставчикът коригира мача след приключването му, затова е преизчислен и балансът ти е коригиран. Този фиш се промени от ${from} на ${to}.<br><br>`,
    yourCard: (crew: string, staked: string, hits: number, of: number, list: string, net: string) =>
      `Твоят фиш${crew}: ${staked} заложени, ${hits} от ${of} познати (${list}) — ${net} по фиша.`,
    inCrew: (crew: string) => ` в ${crew}`,
    up: (n: string) => `на плюс ${n}`,
    down: (n: string) => `на минус ${n}`,
    level: "на нула",
    nothingLanded: "нищо не позна",
    hold: (points: string) => `<br>Държиш ${points}.`,
    points: (n: string) => `${n} точки`,
    overall: (pos: string) => ` Ти си ${pos} в общата класация.`,
    ordinal: (i: number) => {
      const v = i % 100, d = i % 10;
      const suf = v >= 11 && v <= 19 ? "-и"
        : d === 1 ? "-ви" : d === 2 ? "-ри" : d === 3 || d === 4 || d === 9 ? "-ти"
        : d === 7 || d === 8 ? "-ми" : "-и";
      return `${i}${suf}`;
    },
    cta: "Виж равносметката",
  },
  digest: {
    subject: "Петъчният ти екипен бюлетин",
    title: "Седмицата напред",
    fixtures: "Мачове",
    quiet: "Тиха седмица.",
    yourCrews: "Твоите екипи",
    noCrews: "Още няма екипи — направи един и покани груповия чат.",
    crewLine: (crew: string, points: string) => `<b>${crew}</b> — ${points} т.`,
    rival: (score: string) => ` · екип срещу екип ${score}`,
    playing: (n: string) => ` · ${n} играят`,
    cta: "Отвори таблото",
  },
};

const MAIL: Record<Lang, Mail> = { en, tr, bg };
export const mailIn = (lang: unknown): Mail => MAIL[langOf(lang)];
