/* Morpheus – Farbpalette und Hell/Dunkel (2.7, #100).
   Läuft im <head> vor dem ersten Zeichnen, damit nichts aufblitzt (eigene Datei wegen CSP script-src 'self').
   Gespeichert je Benutzer in localStorage; nur Werte aus den festen Listen, sonst Standard (Solarized dunkel = Petrol). */
'use strict';
(function () {
  var PALETTEN = ['solarized', 'gruvbox', 'oblivion', 'sandstone'];
  var MODI = ['dark', 'light', 'system'];
  var K_PAL = 'morpheus.palette', K_MODUS = 'morpheus.theme';
  var root = document.documentElement;
  function lies(k, liste, std) {
    try { var v = localStorage.getItem(k); return liste.indexOf(v) >= 0 ? v : std; } catch (e) { return std; }
  }
  function anwenden(pal, modus) {
    root.setAttribute('data-palette', pal);
    if (modus === 'system') root.removeAttribute('data-theme'); else root.setAttribute('data-theme', modus);
  }
  function get() { return { palette: lies(K_PAL, PALETTEN, 'solarized'), theme: lies(K_MODUS, MODI, 'dark') }; }
  function set(pal, modus) {
    var a = get();
    if (PALETTEN.indexOf(pal) >= 0) a.palette = pal;
    if (MODI.indexOf(modus) >= 0) a.theme = modus;
    try { localStorage.setItem(K_PAL, a.palette); localStorage.setItem(K_MODUS, a.theme); } catch (e) { /* ohne Speicher nur für diese Sitzung */ }
    anwenden(a.palette, a.theme);
    return a;
  }
  var a = get();
  anwenden(a.palette, a.theme);
  window.MorpheusPalette = Object.freeze({ PALETTEN: PALETTEN.slice(), MODI: MODI.slice(), get: get, set: set });
})();
