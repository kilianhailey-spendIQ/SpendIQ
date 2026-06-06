// OCR functions for SpendIQ - PDF statement parsing
// This file must be loaded AFTER pdf.js and tesseract.js

if (typeof pdfjsLib !== 'undefined' && !pdfjsLib.GlobalWorkerOptions.workerSrc) {
  pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';
}

async function _renderPageToCanvas(page, targetDpi = 300) {
  const scale = Math.max(1, (targetDpi || 300) / 72);
  const viewport = page.getViewport({ scale });
  const canvas = document.createElement('canvas');
  const context = canvas.getContext('2d');
  canvas.width = viewport.width;
  canvas.height = viewport.height;
  await page.render({ canvasContext: context, viewport }).promise;
  return canvas;
}

async function _extractPageTextLayer(page) {
  try {
    const textContent = await page.getTextContent({ normalizeWhitespace: true, disableCombineTextItems: false });
    const items = textContent.items || [];
    const strings = items.map((it) => it.str || '').filter(Boolean);
    return { text: strings.join('\n'), raw: textContent };
  } catch (e) {
    return { text: '', raw: null };
  }
}

function _isMappingBad(extractResult) {
  if (!extractResult || !extractResult.text) return true;
  const text = extractResult.text;
  if (text.trim().length < 24) {
    const hasDateLike = /\b\d{1,2}\/\d{1,2}(\/\d{2,4})?\b/.test(text);
    const hasMoneyLike = /\$?\d{1,3}(,\d{3})*(\.\d{2})?/.test(text);
    if (hasDateLike || hasMoneyLike) return false;
  }
  const replacementOrNulls = (text.match(/[\u0000\uFFFD]/g) || []).length;
  if (replacementOrNulls >= 4) return true;
  const printable = (text.match(/[\p{L}\p{N}\p{P}\p{S}]/gu) || []).length;
  const ratio = printable / Math.max(1, text.length);
  return ratio < 0.5;
}

window.ocrSmartExtractFromPdf = async function(bytes, lang, onProgress, onPartial) {
  if (typeof pdfjsLib === 'undefined') throw new Error('pdfjsLib not loaded');
  const loadingTask = pdfjsLib.getDocument({ data: new Uint8Array(bytes) });
  const pdf = await loadingTask.promise;
  const total = pdf.numPages;
  const pagesText = [];
  
  let shouldTryTextLayer = false;
  const sampleCount = Math.min(3, total);
  const sampledPages = [];
  for (let i = 1; i <= sampleCount; i++) {
    const p = await pdf.getPage(i);
    sampledPages.push(p);
    const res = await _extractPageTextLayer(p);
    if (!_isMappingBad(res) && (res.text || '').trim().length >= 12) {
      shouldTryTextLayer = true;
      break;
    }
    await new Promise(r => setTimeout(r, 0));
  }

  if (shouldTryTextLayer) {
    for (let i = 1; i <= total; i++) {
      const page = (i <= sampledPages.length) ? sampledPages[i - 1] : await pdf.getPage(i);
      const res = await _extractPageTextLayer(page);
      const text = res && res.text ? res.text : '';
      if (_isMappingBad(res) && text.trim().length < 200) {
        pagesText.length = 0;
        break;
      }
      pagesText.push(text);
      if (typeof onProgress === 'function') onProgress(i, total);
      if (typeof onPartial === 'function') onPartial(pagesText.join('\n'));
      if ((i % 4) === 0) await new Promise(r => setTimeout(r, 0));
    }
    if (pagesText.length === total) return { pages: pagesText, method: 'text_with_tounicode' };
  }

  if (typeof Tesseract === 'undefined') throw new Error('Tesseract not loaded');
  const worker = await Tesseract.createWorker(lang || 'eng');
  try {
    for (let i = 1; i <= total; i++) {
      const page = await pdf.getPage(i);
      const canvas = await _renderPageToCanvas(page, 300);
      const res = await worker.recognize(canvas);
      const text = (res && res.data && res.data.text) ? res.data.text : '';
      pagesText.push(text);
      if (typeof onProgress === 'function') onProgress(i, total);
      if (typeof onPartial === 'function') onPartial(pagesText.join('\n'));
      await new Promise(r => setTimeout(r, 0));
    }
  } finally {
    await worker.terminate();
  }
  return { pages: pagesText, method: 'ocr_raster_300dpi' };
};

window.ocrRasterOnlyFromPdf = async function(bytes, lang, dpi, onProgress, onPartial) {
  if (typeof pdfjsLib === 'undefined') throw new Error('pdfjsLib not loaded');
  if (typeof Tesseract === 'undefined') throw new Error('Tesseract not loaded');
  
  const loadingTask = pdfjsLib.getDocument({ data: new Uint8Array(bytes), disableFontFace: true, disableRange: true, disableAutoFetch: true, stopAtErrors: true });
  const pdf = await loadingTask.promise;
  const total = pdf.numPages;
  const pagesText = [];
  const targetDpi = (typeof dpi === 'number' && dpi > 0) ? dpi : 300;
  
  const worker = await Tesseract.createWorker(lang || 'eng');
  try {
    for (let i = 1; i <= total; i++) {
      const page = await pdf.getPage(i);
      const canvas = await _renderPageToCanvas(page, targetDpi);
      const res = await worker.recognize(canvas);
      const text = (res && res.data && res.data.text) ? res.data.text : '';
      pagesText.push(text);
      if (typeof onProgress === 'function') onProgress(i, total);
      if (typeof onPartial === 'function') onPartial(pagesText.join('\n'));
      await new Promise(r => setTimeout(r, 0));
    }
  } finally {
    await worker.terminate();
  }
  return { pages: pagesText, method: 'ocr_raster_only', dpi: targetDpi };
};

function _cropCanvasVertical(srcCanvas, topPct, bottomPct) {
  const t = Math.max(0, Math.min(0.9, Number(topPct) || 0));
  const b = Math.max(0, Math.min(0.9, Number(bottomPct) || 0));
  if (t <= 0 && b <= 0) return srcCanvas;
  const sx = 0;
  const sy = Math.floor(srcCanvas.height * t);
  const sw = srcCanvas.width;
  const sh = Math.max(1, Math.floor(srcCanvas.height * (1 - t - b)));
  const dst = document.createElement('canvas');
  dst.width = sw;
  dst.height = sh;
  const dctx = dst.getContext('2d');
  try { if (dctx) dctx.imageSmoothingEnabled = false; } catch (_) {}
  dctx.drawImage(srcCanvas, sx, sy, sw, sh, 0, 0, sw, sh);
  return dst;
}

function _cropCanvasLeft(srcCanvas, leftWidthPct) {
  const wPct = Math.max(0.02, Math.min(0.9, Number(leftWidthPct) || 0.15));
  const sx = 0;
  const sy = 0;
  const sw = Math.max(1, Math.floor(srcCanvas.width * wPct));
  const sh = srcCanvas.height;
  const dst = document.createElement('canvas');
  dst.width = sw;
  dst.height = sh;
  const dctx = dst.getContext('2d');
  try { if (dctx) dctx.imageSmoothingEnabled = false; } catch (_) {}
  dctx.drawImage(srcCanvas, sx, sy, sw, sh, 0, 0, sw, sh);
  return dst;
}

window.ocrRasterOnlyFromPdfCropped = async function(bytes, lang, dpi, cropTop, cropBottom, onProgress, onPartial) {
  if (typeof pdfjsLib === 'undefined') throw new Error('pdfjsLib not loaded');
  if (typeof Tesseract === 'undefined') throw new Error('Tesseract not loaded');
  
  const loadingTask = pdfjsLib.getDocument({ data: new Uint8Array(bytes), disableFontFace: true, disableRange: true, disableAutoFetch: true, stopAtErrors: true });
  const pdf = await loadingTask.promise;
  const total = pdf.numPages;
  const pagesText = [];
  const targetDpi = (typeof dpi === 'number' && dpi > 0) ? dpi : 260;
  const ct = Math.max(0, Math.min(0.4, Number(cropTop) || 0));
  const cb = Math.max(0, Math.min(0.3, Number(cropBottom) || 0));
  
  const worker = await Tesseract.createWorker(lang || 'eng');
  try {
    for (let i = 1; i <= total; i++) {
      const page = await pdf.getPage(i);
      const canvas = await _renderPageToCanvas(page, targetDpi);
      const cropped = _cropCanvasVertical(canvas, ct, cb);
      try { const ctx = cropped.getContext('2d'); if (ctx) ctx.imageSmoothingEnabled = false; } catch (_) {}
      const res = await worker.recognize(cropped);
      const text = (res && res.data && res.data.text) ? res.data.text : '';
      pagesText.push(text);
      if (typeof onProgress === 'function') onProgress(i, total);
      if (typeof onPartial === 'function') onPartial(pagesText.join('\n'));
      await new Promise(r => setTimeout(r, 0));
    }
  } finally {
    await worker.terminate();
  }
  return { pages: pagesText, method: 'ocr_raster_only_cropped', dpi: targetDpi, cropTop: ct, cropBottom: cb };
};

window.ocrRasterDiscoverAdaptiveFromPdf = async function(bytes, lang, dpiFast, dpiFull, cropTop, cropBottom, onProgress, onPartial) {
  if (typeof pdfjsLib === 'undefined') throw new Error('pdfjsLib not loaded');
  if (typeof Tesseract === 'undefined') throw new Error('Tesseract not loaded');
  
  const loadingTask = pdfjsLib.getDocument({ data: new Uint8Array(bytes), disableFontFace: true, disableRange: true, disableAutoFetch: true, stopAtErrors: true });
  const pdf = await loadingTask.promise;
  const total = pdf.numPages;
  const fastDpi = (typeof dpiFast === 'number' && dpiFast > 0) ? dpiFast : 150;
  const fullDpi = (typeof dpiFull === 'number' && dpiFull > 0) ? dpiFull : 200;
  const ct = Math.max(0, Math.min(0.5, Number(cropTop) || 0.12));
  const cb = Math.max(0, Math.min(0.5, Number(cropBottom) || 0.10));
  
  const worker = await Tesseract.createWorker(lang || 'eng');
  
  try {
    async function recognizePageAt(pageIndex, dpi) {
      const page = await pdf.getPage(pageIndex);
      const canvas = await _renderPageToCanvas(page, dpi);
      const cropped = _cropCanvasVertical(canvas, ct, cb);
      try { const ctx = cropped.getContext('2d'); if (ctx) ctx.imageSmoothingEnabled = false; } catch (_) {}
      const res = await worker.recognize(cropped);
      return (res && res.data && res.data.text) ? res.data.text : '';
    }

    const leftStripLooksT = [];
    for (let i = 1; i <= total; i++) {
      const page = await pdf.getPage(i);
      const canvas = await _renderPageToCanvas(page, fastDpi);
      const croppedV = _cropCanvasVertical(canvas, ct, cb);
      const leftStrip = _cropCanvasLeft(croppedV, 0.14);
      try { const ctx = leftStrip.getContext('2d'); if (ctx) ctx.imageSmoothingEnabled = false; } catch (_) {}
      const res = await worker.recognize(leftStrip);
      const t = (res && res.data && res.data.text) ? res.data.text : '';
      const lines = t.split('\n');
      let foundT = false;
      for (let li = 0; li < lines.length; li++) {
        const first = (lines[li] || '').replace(/\u0000/g, '').replace(/^\s+/, '');
        if (first.length > 0 && (first[0] === 'T' || first[0] === 't')) {
          foundT = true;
          break;
        }
      }
      leftStripLooksT.push(foundT);
    }

    function pageLooksLikeTransactions(text) {
      const lines = (text || '').split('\n');
      for (let li = 0; li < lines.length; li++) {
        const l0 = (lines[li] || '').replace(/\u0000/g, '');
        const l1 = (lines[li + 1] || '').replace(/\u0000/g, '');
        const l2 = (lines[li + 2] || '').replace(/\u0000/g, '');
        const norm = (s) => s.replace(/^\s+/, '').replace(/-\s*$/g, '').replace(/[^A-Za-z]+/g, '').toLowerCase();
        const single = lines[li].replace(/^\s+/, '');
        if (/^transactions\b/i.test(single)) return true;
        const twoJoined = `${l0.replace(/-\s*$/g, '')} ${l1}`;
        if (norm(twoJoined).startsWith('transactions')) return true;
        const threeJoined = `${l0.replace(/-\s*$/g, '')} ${l1.replace(/-\s*$/g, '')} ${l2}`;
        if (norm(threeJoined).startsWith('transactions')) return true;
      }
      return false;
    }

    let firstTxPage = -1;
    for (let i = 0; i < total; i++) {
      if (!leftStripLooksT[i]) continue;
      const confirmText = await recognizePageAt(i + 1, fastDpi);
      if (pageLooksLikeTransactions(confirmText)) {
        firstTxPage = i + 1;
        break;
      }
    }

    const finalTexts = [];
    let done = 0;

    if (firstTxPage === -1) {
      for (let i = 0; i < total; i++) {
        finalTexts.push('');
        done++;
        if (typeof onProgress === 'function') onProgress(done, total);
        if (typeof onPartial === 'function') onPartial(finalTexts.filter(t => t && t.length > 0).join('\n'));
      }
    } else {
      for (let i = 0; i < firstTxPage - 1; i++) {
        finalTexts.push('');
        done++;
        if (typeof onProgress === 'function') onProgress(done, total);
        if (typeof onPartial === 'function') onPartial(finalTexts.filter(t => t && t.length > 0).join('\n'));
      }

      for (let i = firstTxPage; i <= total; i++) {
        const hi = await recognizePageAt(i, fullDpi);
        finalTexts.push(hi || '');
        done++;
        if (typeof onProgress === 'function') onProgress(done, total);
        if (typeof onPartial === 'function') onPartial(finalTexts.filter(t => t && t.length > 0).join('\n'));
      }
    }

    return { pages: finalTexts, method: 'ocr_raster_discover_adaptive', dpiFast: fastDpi, dpiFull: fullDpi, cropTop: ct, cropBottom: cb };
  } finally {
    await worker.terminate();
  }
};
