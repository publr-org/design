// PublrDesign's own icons, drawn for the editor shell: 24 x 24 boxes with 1 px lines,
// shown at 24 CSS px (the size the editor's toolbars and panels use). None is copied
// from anywhere. Each is added to the page's icon sprite once (`installIcons`) and drawn
// as a `<use>` (PdIcon.ptsx).

/** Line art: drawn with a 1 px round stroke in the current colour. */
const L = (body: string) => `<g fill="none" stroke="currentColor" stroke-width="1" stroke-linecap="round" stroke-linejoin="round">${body}</g>`;
/** Solid art in the current colour. */
const S = (body: string) => `<g fill="currentColor" stroke="none">${body}</g>`;

export const PD_ICONS = {
  // ---------------------------------------------------------------- the mark and the rail
  // Publr's mark (site/apps/shared/components/mark.publr, 34 x 34): a dot at the centre,
  // rings of dots around it; drawn 20 px in the 24 px box.
  mark: S(`<g transform="translate(2 2) scale(0.5882)"><path d="M19.598 18.5C18.7696 19.9349 16.9348 20.4265 15.4999 19.5981C14.065 18.7696 13.5734 16.9349 14.4018 15.5C15.2303 14.0651 17.065 13.5735 18.4999 14.4019C19.9348 15.2303 20.4264 17.0651 19.598 18.5Z"/><path d="M23.232 10.2058C22.6797 11.1623 21.4565 11.4901 20.4999 10.9378C19.5433 10.3855 19.2156 9.16235 19.7679 8.20576C20.3201 7.24918 21.5433 6.92143 22.4999 7.47371C23.4565 8.026 23.7842 9.24918 23.232 10.2058Z"/><path d="M19.7679 25.7944C19.2156 24.8378 19.5433 23.6146 20.4999 23.0623C21.4565 22.51 22.6797 22.8378 23.232 23.7944C23.7843 24.7509 23.4565 25.9741 22.4999 26.5264C21.5433 27.0787 20.3202 26.7509 19.7679 25.7944Z"/><path d="M25.9999 19.0001C24.8953 19.0001 23.9999 18.1047 23.9999 17.0001C23.9999 15.8956 24.8953 15.0001 25.9999 15.0001C27.1045 15.0001 27.9999 15.8956 27.9999 17.0001C27.9999 18.1047 27.1045 19.0001 25.9999 19.0001Z"/><path d="M14.232 25.7942C13.6797 26.7508 12.4565 27.0786 11.4999 26.5263C10.5433 25.974 10.2156 24.7508 10.7679 23.7942C11.3201 22.8376 12.5433 22.5099 13.4999 23.0622C14.4565 23.6145 14.7842 24.8376 14.232 25.7942Z"/><path d="M10.7679 10.2059C10.2157 9.24936 10.5434 8.02618 11.5 7.4739C12.4566 6.92161 13.6798 7.24936 14.232 8.20595C14.7843 9.16253 14.4566 10.3857 13.5 10.938C12.5434 11.4903 11.3202 11.1625 10.7679 10.2059Z"/><path d="M7.99999 19.0002C6.89542 19.0002 5.99999 18.1047 5.99999 17.0002C5.99999 15.8956 6.89542 15.0002 7.99999 15.0002C9.10456 15.0002 9.99999 15.8956 9.99999 17.0002C9.99999 18.1047 9.10456 19.0002 7.99999 19.0002Z"/><path d="M25.8659 3.64359C25.5898 4.12188 24.9782 4.28575 24.4999 4.00961C24.0216 3.73347 23.8577 3.12188 24.1339 2.64359C24.41 2.16529 25.0216 2.00142 25.4999 2.27756C25.9782 2.5537 26.1421 3.16529 25.8659 3.64359Z"/><path d="M33.0001 18.0002C32.4478 18.0002 32.0001 17.5524 32.0001 17.0002C32.0001 16.4479 32.4478 16.0002 33.0001 16.0002C33.5523 16.0002 34.0001 16.4479 34.0001 17.0002C34.0001 17.5524 33.5523 18.0002 33.0001 18.0002Z"/><path d="M31.3561 9.86594C30.8778 10.1421 30.2663 9.97821 29.9901 9.49992C29.714 9.02162 29.8778 8.41003 30.3561 8.13389C30.8344 7.85775 31.446 8.02162 31.7222 8.49992C31.9983 8.97821 31.8344 9.5898 31.3561 9.86594Z"/><path d="M30.3563 25.866C29.878 25.5899 29.7141 24.9783 29.9903 24.5C30.2664 24.0217 30.878 23.8578 31.3563 24.134C31.8346 24.4101 31.9985 25.0217 31.7223 25.5C31.4462 25.9783 30.8346 26.1422 30.3563 25.866Z"/><path d="M16.0001 33.0001C16.0001 32.4478 16.4478 32.0001 17.0001 32.0001C17.5524 32.0001 18.0001 32.4478 18.0001 33.0001C18.0001 33.5524 17.5524 34.0001 17.0001 34.0001C16.4478 34.0001 16.0001 33.5524 16.0001 33.0001Z"/><path d="M24.134 31.3566C23.8579 30.8783 24.0218 30.2667 24.5001 29.9905C24.9784 29.7144 25.59 29.8783 25.8661 30.3566C26.1422 30.8349 25.9784 31.4464 25.5001 31.7226C25.0218 31.9987 24.4102 31.8349 24.134 31.3566Z"/><path d="M9.86593 31.3564C9.58978 31.8347 8.97819 31.9986 8.4999 31.7224C8.02161 31.4463 7.85773 30.8347 8.13388 30.3564C8.41002 29.8781 9.02161 29.7142 9.4999 29.9904C9.97819 30.2665 10.1421 30.8781 9.86593 31.3564Z"/><path d="M1 18.0001C0.447715 18.0001 -3.44684e-08 17.5524 0 17.0001C3.44684e-08 16.4478 0.447715 16.0001 1 16.0001C1.55228 16.0001 2 16.4478 2 17.0001C2 17.5524 1.55228 18.0001 1 18.0001Z"/><path d="M3.64329 25.866C3.16499 26.1422 2.5534 25.9783 2.27726 25.5C2.00112 25.0217 2.16499 24.4101 2.64329 24.134C3.12158 23.8578 3.73317 24.0217 4.00931 24.5C4.28545 24.9783 4.12158 25.5899 3.64329 25.866Z"/><path d="M2.6435 9.86602C2.1652 9.58987 2.00133 8.97828 2.27747 8.49999C2.55361 8.0217 3.1652 7.85782 3.6435 8.13397C4.12179 8.41011 4.28566 9.0217 4.00952 9.49999C3.73338 9.97828 3.12179 10.1422 2.6435 9.86602Z"/><path d="M16.0001 1C16.0001 0.447715 16.4478 -4.87226e-08 17.0001 0C17.5524 4.87226e-08 18.0001 0.447715 18.0001 1C18.0001 1.55228 17.5524 2 17.0001 2C16.4478 2 16.0001 1.55228 16.0001 1Z"/><path d="M8.13398 3.64371C7.85783 3.16542 8.02171 2.55383 8.5 2.27768C8.97829 2.00154 9.58988 2.16542 9.86603 2.64371C10.1422 3.122 9.97829 3.73359 9.5 4.00973C9.02171 4.28588 8.41012 4.122 8.13398 3.64371Z"/></g>`),
  file: L(`<path d="M8.5 5.5h5l3 3v9a1 1 0 0 1-1 1h-7a1 1 0 0 1-1-1v-11a1 1 0 0 1 1-1z"/><path d="M13.5 5.5v3h3"/>`),
  assets: L(`<circle cx="12" cy="12" r="6.5"/><path d="M12 9v6M9 12h6"/>`),
  tools: L(`<rect x="5.5" y="9" width="13" height="9" rx="1.5"/><path d="M9.5 9V7.5a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1V9M5.5 13h13M10.5 12v2M13.5 12v2"/>`),
  agents: L(`<path d="M12 5.5c.55 3.4 3.1 5.95 6.5 6.5-3.4.55-5.95 3.1-6.5 6.5-.55-3.4-3.1-5.95-6.5-6.5 3.4-.55 5.95-3.1 6.5-6.5z"/>`),
  variables: L(`<path d="M12 4.75 18.3 8.4v7.2L12 19.25 5.7 15.6V8.4z"/><circle cx="12" cy="12" r="2.25"/>`),
  // ---------------------------------------------------------------- tools
  move: L(`<path d="M6.1 3.5 18.55 13.55l-5.75.9-3.15 5z"/>`),
  hand: L(`<path d="M 8.4 12.6 V 6.3 a 1.5 1.5 0 0 1 3 0 V 11.4 M 11.4 10.8 V 5.1 a 1.5 1.5 0 0 1 3 0 V 11.4 M 14.4 11.4 V 6.3 a 1.5 1.5 0 0 1 3 0 v 7.5 c 0 3.6-2.4 6-6 6 h-.6 c-2.4 0-3.85-1.1-5.05-2.9 L 3.6 13.7 a 1.45 1.45 0 0 1 2.3-1.7 L 8.4 14.4"/>`),
  scale: L(`<path d="M 4.5 19.5 19.5 4.5 M 11.3 4.5 h 8.15 v 8.15 M 4.5 11.3 v 8.15 h 8.15"/>`),
  frame: L(`<path d="M8.5 4.5v15M15.5 4.5v15M4.5 8.5h15M4.5 15.5h15"/>`),
  section: L(`<rect x="4.5" y="6.8" width="14.95" height="12.65" rx="1.15"/><path d="M 4.5 6.8 V 5.1 a .6 .6 0 0 1 .6-.6 h 5.75 a .6 .6 0 0 1 .6 .6 v 1.7"/>`),
  slice: L(`<path d="M 5.4 18.6 15.85 8.15 l 2.2-2.2 a 1.55 1.55 0 0 1 2.2 2.2 l-2.2 2.2 L 7.6 20.8 M 14.2 9.8 l 2.2 2.2"/>`),
  rectangle: L(`<rect x="4.5" y="4.5" width="15" height="15" rx="1.5"/>`),
  line: L(`<path d="M 4.5 19.5 19.5 4.5"/>`),
  arrow: L(`<path d="M 4.5 19.5 19.5 4.5 M 11.3 4.5 h 8.15 v 8.15"/>`),
  ellipse: L(`<circle cx="12" cy="12" r="7.5"/>`),
  polygon: L(`<path d="M 12 4.8 19.8 18.9 H 4.2z"/>`),
  star: L(`<path d="m 12 4.2 2.3 5.05 5.5 .6-4.1 3.7 1.2 5.4-4.9-2.75-4.9 2.75 1.2-5.4-4.1-3.7 5.5-.6z"/>`),
  image: L(`<rect x="4.5" y="5.7" width="14.95" height="12.65" rx="1.15"/><circle cx="9.1" cy="9.7" r="1.45"/><path d="m 6.3 18.4 4.6-4 3.45 2.9 2.9-2.3 4 3.45"/>`),
  pen: L(`<path d="M12 4.35 17.9 12l-2.95 6.5h-5.9L6.1 12z"/><path d="M12 4.35v5.9"/><circle cx="12" cy="12" r="1.45"/><path d="M9.05 20.85h5.9"/>`),
  pencil: L(`<path d="M 16.15 4.6 19.4 7.85 8.45 18.8 l-4.15 .9 .9-4.15z M 13.75 7 l 3.25 3.25"/>`),
  text: L(`<path d="M4.5 6.5v-2h15v2M12 4.5v15M9.5 19.5h5"/>`),
  comment: L(`<path d="M12 4.2a7.8 7.8 0 1 1-3.7 14.65L4.2 19.8l.95-4.1A7.8 7.8 0 0 1 12 4.2z"/>`),
  actions: L(`<path d="M8.4 4.2 12 7.8 8.4 11.4 4.8 7.8z"/><circle cx="16.2" cy="7.8" r="3.3"/><rect x="5.1" y="13.5" width="6.6" height="6.6" rx=".9"/><path d="M16.2 13.2v7.2M12.6 16.8h7.2"/>`),
  "code-layer": L(`<path d="M8.7 4.75c-2 0-2.65.65-2.65 2.65v2c0 1.3-.65 2.65-2 2.65 1.3 0 2 1.3 2 2.65v2c0 2 .65 2.65 2.65 2.65M15.3 4.75c2 0 2.65.65 2.65 2.65v2c0 1.3.65 2.65 2 2.65-1.3 0-2 1.3-2 2.65v2c0 2-.65 2.65-2.65 2.65"/>`),
  draw: L(`<path d="M6 16.5c1.5-4.5 3.5-8 5-8 2 0-1.5 7.5.5 7.5 1.5 0 3-4.5 4.5-4.5 1.2 0 .5 3 1.5 3 .6 0 1-.5 1.5-1"/>`),
  design: L(`<rect x="5.5" y="5.5" width="13" height="13" rx="1.5"/><path d="M5.5 9.5h13M9.5 9.5v9"/><path d="m12.5 12.5 5 2-2 .8-.8 2z"/>`),
  motion: L(`<path d="m12 5.5 6.5 6.5-6.5 6.5L5.5 12z"/><path d="m9.5 12 2.5-2.5M10.5 14.5l4-4"/>`),
  dev: L(`<path d="m9.5 8.5-3.5 3.5 3.5 3.5M14.5 8.5l3.5 3.5-3.5 3.5M13 7l-2 10"/>`),
  // ---------------------------------------------------------------- layer kinds (16 px glyphs)
  "l-frame": L(`<path d="M9.5 7.5v9M14.5 7.5v9M7.5 9.5h9M7.5 14.5h9"/>`),
  "l-group": L(`<path d="M7 7h2M11 7h2M15 7h2v2M17 11v2M17 15v2h-2M13 17h-2M9 17H7v-2M7 13v-2M7 9V7"/>`),
  "l-section": L(`<rect x="6.5" y="8.5" width="11" height="9" rx=".75"/><path d="M6.5 8.5V7a.5.5 0 0 1 .5-.5h4a.5.5 0 0 1 .5.5v1.5"/>`),
  "l-component": L(`<path d="m12 6 2.25 2.25L12 10.5 9.75 8.25zM12 13.5l2.25 2.25L12 18l-2.25-2.25zM8.25 9.75 10.5 12l-2.25 2.25L6 12zM15.75 9.75 18 12l-2.25 2.25L13.5 12z"/>`),
  "l-component-set": L(`<path d="m12 6 2.25 2.25L12 10.5 9.75 8.25zM12 13.5l2.25 2.25L12 18l-2.25-2.25zM8.25 9.75 10.5 12l-2.25 2.25L6 12zM15.75 9.75 18 12l-2.25 2.25L13.5 12z" stroke-dasharray="1.5 1.5"/>`),
  "l-instance": L(`<path d="m12 6.5 5.5 5.5-5.5 5.5L6.5 12z"/>`),
  "l-text": L(`<path d="M7.5 8.5v-1.5h9v1.5M12 7v10M10.25 17h3.5"/>`),
  "l-rectangle": L(`<rect x="7" y="7" width="10" height="10" rx=".75"/>`),
  "l-ellipse": L(`<circle cx="12" cy="12" r="5"/>`),
  "l-line": L(`<path d="M7 17 17 7"/>`),
  "l-vector": L(`<path d="M7 16.5c2-6.5 8-3 10-9"/><rect x="5.75" y="15.75" width="2.5" height="2.5" rx=".4"/><rect x="15.75" y="5.75" width="2.5" height="2.5" rx=".4"/>`),
  "l-star": L(`<path d="m12 6.5 1.6 3.4 3.7.4-2.8 2.5.8 3.7-3.3-1.9-3.3 1.9.8-3.7-2.8-2.5 3.7-.4z"/>`),
  "l-polygon": L(`<path d="M12 7 17 16.5H7z"/>`),
  "l-boolean": L(`<rect x="6.5" y="6.5" width="7" height="7" rx=".5"/><rect x="10.5" y="10.5" width="7" height="7" rx=".5"/>`),
  "l-slice": L(`<path d="m7 17 7.5-7.5 2-2a1.06 1.06 0 0 1 1.5 1.5l-2 2L8.5 18.5"/>`),
  "l-image": L(`<rect x="6.5" y="7" width="11" height="10" rx=".75"/><circle cx="9.75" cy="10.25" r="1"/><path d="m6.5 15.5 3.5-3 2.5 2 2-1.5 3 2.5"/>`),
  "l-row": L(`<path d="M7.5 7v10M12 7v10M16.5 7v10"/>`),
  "l-column": L(`<path d="M7 7.5h10M7 12h10M7 16.5h10"/>`),
  "l-grid": L(`<rect x="7" y="7" width="4" height="4" rx=".5"/><rect x="13" y="7" width="4" height="4" rx=".5"/><rect x="7" y="13" width="4" height="4" rx=".5"/><rect x="13" y="13" width="4" height="4" rx=".5"/>`),
  "l-mask": L(`<circle cx="12" cy="12" r="5.5"/><path d="M12 6.5a5.5 5.5 0 0 0 0 11z" fill="currentColor"/>`),
  // ---------------------------------------------------------------- small controls
  "chevron-down": L(`<path d="m9.5 11 2.5 2.5 2.5-2.5"/>`),
  "chevron-right": L(`<path d="m11 9.5 2.5 2.5-2.5 2.5"/>`),
  "caret-down": S(`<path d="M9.5 10.75h5L12 13.5z"/>`),
  eye: L(`<path d="M5.5 12s2.5-4.5 6.5-4.5 6.5 4.5 6.5 4.5-2.5 4.5-6.5 4.5S5.5 12 5.5 12z"/><circle cx="12" cy="12" r="2"/>`),
  "eye-off": L(`<path d="M6.5 10c1.3 1.7 3.2 3 5.5 3s4.2-1.3 5.5-3M8.5 12.2 7.3 14M15.5 12.2l1.2 1.8M12 13v2.25"/>`),
  lock: L(`<rect x="8" y="11" width="8" height="6.5" rx="1"/><path d="M9.75 11V9a2.25 2.25 0 0 1 4.5 0v2"/>`),
  unlock: L(`<rect x="8" y="11" width="8" height="6.5" rx="1"/><path d="M9.75 11V9a2.25 2.25 0 0 1 4.4-.7"/>`),
  plus: L(`<path d="M12 6.5v11M6.5 12h11"/>`),
  minus: L(`<path d="M6.5 12h11"/>`),
  search: L(`<circle cx="11" cy="11" r="4.75"/><path d="m14.5 14.5 3.5 3.5"/>`),
  sidebar: L(`<rect x="5.5" y="6.5" width="13" height="11" rx="1.5"/><path d="M9.5 6.5v11"/>`),
  play: L(`<path d="M7.5 4.5v15L19 12z"/>`),
  more: S(`<circle cx="7" cy="12" r="1.25"/><circle cx="12" cy="12" r="1.25"/><circle cx="17" cy="12" r="1.25"/>`),
  styles: L(`<circle cx="9" cy="9" r="2"/><circle cx="15" cy="9" r="2"/><circle cx="9" cy="15" r="2"/><circle cx="15" cy="15" r="2"/>`),
  collapse: L(`<path d="M7 12h10M12 5.5v3M10.5 7l1.5 1.5L13.5 7M12 18.5v-3M10.5 17l1.5-1.5 1.5 1.5"/>`),
  check: L(`<path d="m7 12.5 3.25 3L17 8.75"/>`),
  upvote: L(`<path d="M12 16.5v-9M8 11.5l4-4 4 4"/>`),
  vote: `<path d="M12 7.5 17 14H7z" fill="currentColor" stroke="currentColor" stroke-width="1" stroke-linejoin="round"/>`,
  bell: L(`<path d="M8.5 15.5h7l-1-1.5v-3a2.5 2.5 0 0 0-5 0v3zM11 17.5a1 1 0 0 0 2 0"/>`),
  close: L(`<path d="m7.5 7.5 9 9M16.5 7.5l-9 9"/>`),
  back: L(`<path d="M13.5 8 9.5 12l4 4"/>`),
  // Return to instance: an arrow that turns back on itself.
  "return": L(`<path d="M9.5 8.5 6 12l3.5 3.5M6 12h8a3.5 3.5 0 0 0 0-7h-1"/>`),
  // ---------------------------------------------------------------- variables
  // A colour variable's mark: a painter's palette.
  "var-color": L(`<path d="M12 5.5c3.6 0 6.5 2.6 6.5 5.8 0 1.9-1.5 3.2-3.4 3.2h-1.5c-.8 0-1.3.8-.9 1.5l.3.5c.5.9-.1 2-1.1 2A6.5 6.5 0 0 1 12 5.5z"/><circle cx="8.9" cy="11.6" r=".8" fill="currentColor" stroke="none"/><circle cx="10.4" cy="8.7" r=".8" fill="currentColor" stroke="none"/><circle cx="13.6" cy="8.5" r=".8" fill="currentColor" stroke="none"/><circle cx="15.9" cy="10.6" r=".8" fill="currentColor" stroke="none"/>`),
  // Search filters: a disc with three narrowing lines.
  filter: L(`<circle cx="12" cy="12" r="6.5"/><path d="M8.75 10h6.5M9.75 12.25h4.5M11 14.5h2"/>`),
  // Close or open every group: three lines, a chevron down and one up beside them.
  "collapse-all": L(`<path d="M5.5 7.5h7M5.5 12h7M5.5 16.5h7M15 7.25l1.75 1.75 1.75-1.75M15 16.75l1.75-1.75 1.75 1.75"/>`),
  // Edit a variable or a collection: two upright sliders, the left knob low, the right high.
  adjust: L(`<path d="M9.5 6.5v5.75M9.5 15.75v1.75M14.5 6.5v1.75M14.5 11.75v5.75"/><circle cx="9.5" cy="14" r="1.75"/><circle cx="14.5" cy="10" r="1.75"/>`),
  "var-number": L(`<path d="M10.25 7 9 17M15 7l-1.25 10M7.5 10.25h10M6.5 13.75h10"/>`),
  "var-string": L(`<path d="M5.5 16.5 8.75 7.5 12 16.5M6.7 13.5h4.1M16 11.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5zM18.5 11.5v5"/>`),
  "var-boolean": L(`<rect x="5.5" y="8.5" width="13" height="7" rx="3.5"/><circle cx="15" cy="12" r="1.75"/>`),
  detach: L(`<path d="M9.5 11.5 8 13a2.1 2.1 0 0 0 3 3l1.5-1.5M14.5 12.5 16 11a2.1 2.1 0 0 0-3-3l-1.5 1.5M6.5 6.5l1.75 1.75M17.5 17.5l-1.75-1.75"/>`),
  sliders: L(`<path d="M6.5 9h4.25M14.25 9h3.25M6.5 15h3.25M13.25 15h4.25"/><circle cx="12.5" cy="9" r="1.75"/><circle cx="11.5" cy="15" r="1.75"/>`),
  expand: L(`<path d="M13.5 6.5h4v4M10.5 17.5h-4v-4M17.5 6.5 13 11M6.5 17.5 11 13"/>`),
  shrink: L(`<path d="M17.5 10.5h-4v-4M6.5 13.5h4v4M13.5 10.5 18 6M10.5 13.5 6 18"/>`),
  mode: L(`<circle cx="12" cy="12" r="5.5"/><path d="M12 6.5a5.5 5.5 0 0 1 0 11z" fill="currentColor"/>`),
  // ---------------------------------------------------------------- the design panel
  "align-left": L(`<path d="M6.5 6v12"/><rect x="8.5" y="8" width="9" height="3" rx=".5"/><rect x="8.5" y="13" width="5" height="3" rx=".5"/>`),
  "align-h-center": L(`<path d="M12 6v12"/><rect x="7.5" y="8" width="9" height="3" rx=".5"/><rect x="9.5" y="13" width="5" height="3" rx=".5"/>`),
  "align-right": L(`<path d="M17.5 6v12"/><rect x="6.5" y="8" width="9" height="3" rx=".5"/><rect x="10.5" y="13" width="5" height="3" rx=".5"/>`),
  "align-top": L(`<path d="M6 6.5h12"/><rect x="8" y="8.5" width="3" height="9" rx=".5"/><rect x="13" y="8.5" width="3" height="5" rx=".5"/>`),
  "align-v-center": L(`<path d="M6 12h12"/><rect x="8" y="7.5" width="3" height="9" rx=".5"/><rect x="13" y="9.5" width="3" height="5" rx=".5"/>`),
  "align-bottom": L(`<path d="M6 17.5h12"/><rect x="8" y="6.5" width="3" height="9" rx=".5"/><rect x="13" y="10.5" width="3" height="5" rx=".5"/>`),
  distribute: L(`<path d="M7 7.5h10M7 16.5h10M9 12h6"/>`),
  angle: L(`<path d="M7 7v10h10M7 12.5a4.5 4.5 0 0 1 4.5 4.5"/>`),
  "rotate-90": L(`<path d="M8 12a4 4 0 1 1 4 4M6.5 10.5 8 12l1.5-1.5"/><rect x="10" y="10" width="4" height="4" rx=".5" transform="rotate(45 12 12)"/>`),
  "flip-h": L(`<path d="M12 6v12M10 8.5 6.5 12 10 15.5zM14 8.5l3.5 3.5-3.5 3.5z"/>`),
  "flip-v": L(`<path d="M6 12h12M8.5 10 12 6.5 15.5 10zM8.5 14l3.5 3.5 3.5-3.5z"/>`),
  "flow-free": L(`<rect x="7" y="7" width="4" height="4" rx="1"/><rect x="13" y="9" width="4" height="4" rx="1"/><rect x="9" y="13" width="4" height="4" rx="1"/>`),
  "flow-vertical": L(`<rect x="7" y="6.5" width="6" height="4" rx="1"/><rect x="7" y="13.5" width="6" height="4" rx="1"/><path d="M16.5 7v10M15 15.5l1.5 1.5 1.5-1.5"/>`),
  "flow-horizontal": L(`<rect x="6.5" y="7" width="4" height="6" rx="1"/><rect x="13.5" y="7" width="4" height="6" rx="1"/><path d="M7 16.5h10M15.5 15l1.5 1.5-1.5 1.5"/>`),
  "flow-grid": L(`<rect x="6.5" y="6.5" width="4.5" height="4.5" rx="1"/><rect x="13" y="6.5" width="4.5" height="4.5" rx="1"/><rect x="6.5" y="13" width="4.5" height="4.5" rx="1"/><rect x="13" y="13" width="4.5" height="4.5" rx="1"/>`),
  "auto-layout": L(`<rect x="6.5" y="6.5" width="5" height="11" rx="1"/><path d="M15 9v6M12 12h6"/>`),
  "resize-fit": L(`<path d="M7 7l3 3M10 7.5V10H7.5M17 7l-3 3M14 7.5V10h2.5M7 17l3-3M10 16.5V14H7.5M17 17l-3-3M14 16.5V14h2.5"/>`),
  "aspect-lock": L(`<rect x="6.5" y="6.5" width="11" height="11" rx="1.5"/><path d="M9.5 14.5l5-5M11.5 9.5h3v3"/>`),
  "gap-h": L(`<path d="M7.5 7v10M16.5 7v10M10.5 12h3"/>`),
  "gap-v": L(`<path d="M7 7.5h10M7 16.5h10M12 10.5v3"/>`),
  "pad-h": L(`<rect x="6.5" y="7" width="11" height="10" rx="1"/><path d="M9 9.5v5M15 9.5v5"/>`),
  "pad-v": L(`<rect x="7" y="6.5" width="10" height="11" rx="1"/><path d="M9.5 9h5M9.5 15h5"/>`),
  "pad-sides": L(`<rect x="6.5" y="6.5" width="11" height="11" rx="1" stroke-dasharray="2 2"/>`),
  opacity: L(`<rect x="6.5" y="6.5" width="11" height="11" rx="1.5"/><path d="M9 9h1.5v1.5H9zM12 9h1.5v1.5H12zM10.5 10.5H12V12h-1.5zM13.5 10.5H15V12h-1.5zM9 12h1.5v1.5H9zM12 12h1.5v1.5H12zM10.5 13.5H12V15h-1.5zM13.5 13.5H15V15h-1.5z" fill="currentColor" stroke="none"/>`),
  radius: L(`<path d="M7 17v-6a4 4 0 0 1 4-4h6"/>`),
  "radius-sides": L(`<path d="M6.5 9.5v-1a2 2 0 0 1 2-2h1M14.5 6.5h1a2 2 0 0 1 2 2v1M17.5 14.5v1a2 2 0 0 1-2 2h-1M9.5 17.5h-1a2 2 0 0 1-2-2v-1"/>`),
  blend: L(`<path d="M12 6c2.5 3 4.5 5.5 4.5 8a4.5 4.5 0 0 1-9 0c0-2.5 2-5 4.5-8z"/>`),
  "text-left": L(`<path d="M7 8.5h10M7 12h6M7 15.5h10"/>`),
  "text-center": L(`<path d="M7 8.5h10M9 12h6M7 15.5h10"/>`),
  "text-right": L(`<path d="M7 8.5h10M11 12h6M7 15.5h10"/>`),
  "text-justify": L(`<path d="M7 8.5h10M7 12h10M7 15.5h10"/>`),
  "valign-top": L(`<path d="M7 7.5h10M12 17v-6.5M9.5 13 12 10.5l2.5 2.5"/>`),
  "valign-middle": L(`<path d="M7 12h10M12 6.5V10M10.25 8.5 12 10.25 13.75 8.5M12 17.5V14M10.25 15.5 12 13.75l1.75 1.75"/>`),
  "valign-bottom": L(`<path d="M7 16.5h10M12 7v6.5M9.5 11l2.5 2.5 2.5-2.5"/>`),
  "text-settings": L(`<path d="M8.5 6.5v11M15.5 6.5v11M7 10h3M14 14h3"/>`),
  "line-height": L(`<path d="M7 6.5h10M7 17.5h10M9.5 15l2.5-6 2.5 6M10.25 13.25h3.5"/>`),
  "letter-spacing": L(`<path d="M6.5 7v10M17.5 7v10M9.5 15l2.5-6 2.5 6M10.25 13.25h3.5"/>`),
  "resize-width": L(`<path d="M6.5 12h11M15.5 10l2 2-2 2M8.5 10l-2 2 2 2M6.5 7.5v9M17.5 7.5v9" />`),
  "resize-height": L(`<path d="M12 6.5v11M10 8.5l2-2 2 2M10 15.5l2 2 2-2M7.5 6.5h9M7.5 17.5h9"/>`),
  "resize-fixed": L(`<rect x="6.5" y="6.5" width="11" height="11" rx="1"/><path d="M9.5 9.5h5M9.5 12h5M9.5 14.5h3"/>`),
  "clip-content": L(`<rect x="6.5" y="6.5" width="11" height="11" rx="1"/><path d="M6.5 12h4v5.5"/>`),
  "constraint-h": L(`<path d="M6.5 12h3M14.5 12h3M9.5 10v4M14.5 10v4"/>`),
  "constraint-v": L(`<path d="M12 6.5v3M12 14.5v3M10 9.5h4M10 14.5h4"/>`),
  "effect-shadow": L(`<rect x="6.5" y="6.5" width="9" height="9" rx="1"/><path d="M17.5 9v8.5H9" opacity=".5"/>`),
  "effect-blur": L(`<circle cx="12" cy="12" r="5.5" stroke-dasharray="1.5 1.5"/>`),
  // The styles list's effect styles (13 x 14 px glyphs, as the list's other marks).
  "style-shadow": L(`<rect x="6" y="5.5" width="10.5" height="10.5" rx="2"/><path d="M18.5 8.5v8a2 2 0 0 1-2 2h-8" opacity=".5"/>`),
  "style-blur": L(`<circle cx="12" cy="12" r="6.5" stroke-dasharray="1.6 1.6"/>`),
  "grid-columns": L(`<path d="M8.5 6.5v11M12 6.5v11M15.5 6.5v11"/><rect x="6.5" y="6.5" width="11" height="11" rx="1"/>`),
  link: L(`<path d="M10.5 13.5l3-3M9.5 11.5 8 13a2.1 2.1 0 0 0 3 3l1.5-1.5M14.5 12.5 16 11a2.1 2.1 0 0 0-3-3l-1.5 1.5"/>`),
  warning: S(`<path d="M12 4.5 20.5 19h-17zm-.75 5v4.5h1.5V9.5zm0 6v1.5h1.5V15.5z" fill-rule="evenodd"/>`),
  eyedropper: L(`<path d="m14.5 6.5 3 3M16 5a2.12 2.12 0 0 1 3 3l-1.5 1.5-3-3zM14.5 8 7 15.5 6 18l2.5-1L16 9.5"/>`),
  trash: L(`<path d="M6.5 8.5h11M10 8.5V7a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v1.5M8 8.5l.7 9.1a1 1 0 0 0 1 .9h4.6a1 1 0 0 0 1-.9l.7-9.1"/>`),
  "align-grid": L(`<rect x="5.5" y="5.5" width="13" height="13" rx="1.5"/>`),
  info: L(`<circle cx="12" cy="12" r="6.5"/><path d="M12 11v4.5"/><circle cx="12" cy="8.75" r=".25"/>`),
  sun: L(`<circle cx="12" cy="12" r="3"/><path d="M12 5.5v1.5M12 17v1.5M5.5 12H7M17 12h1.5M7.4 7.4l1 1M15.6 15.6l1 1M7.4 16.6l1-1M15.6 8.4l1-1"/>`),
};

export type PdIconName = keyof typeof PD_ICONS;

let installed = false;

/** Adds the editor's icons to the page's sprite (once). */
export function installIcons(): void {
  if (installed || typeof document === "undefined") return;
  installed = true;
  let sprite = document.getElementById("publr-icon-sprite");
  if (!sprite) {
    sprite = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    sprite.id = "publr-icon-sprite";
    sprite.setAttribute("style", "position:absolute;width:0;height:0;overflow:hidden");
    sprite.setAttribute("aria-hidden", "true");
    document.body.append(sprite);
  }
  const parts: string[] = [];
  for (const [name, body] of Object.entries(PD_ICONS)) parts.push(`<symbol id="pd-icon-${name}" viewBox="0 0 24 24">${body}</symbol>`);
  sprite.insertAdjacentHTML("beforeend", parts.join(""));
}
