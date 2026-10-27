// node render_pdf.js entrada.html saida.pdf
// Converte o HTML do onboarding em PDF A4 e falha se alguma página estourar a altura.
const path = require('path');
const { chromium } = require('playwright');

(async () => {
  const [, , entrada, saida] = process.argv;
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto('file://' + path.resolve(entrada), { waitUntil: 'networkidle' });
  await page.emulateMedia({ media: 'print' });
  const estouradas = await page.$$eval('.page', ps =>
    ps.map((p, i) => (p.scrollHeight > p.clientHeight + 1 ? i + 1 : 0)).filter(Boolean));
  await page.pdf({ path: saida, format: 'A4', printBackground: true, preferCSSPageSize: true });
  await browser.close();
  if (estouradas.length) {
    console.error(`conteúdo cortado nas páginas: ${estouradas.join(', ')}`);
    process.exit(2);
  }
})();
