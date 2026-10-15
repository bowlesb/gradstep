# Line width and reading mode (2026-10-15)

Owner: "in the Mac and web apps, it lacks a truly word wrap option as in when your reading space gets wider there
should be new words on a line. It doesn't necessarily need to be every width but there needs to be some option.
Connected is a really good full screen reading mode for Mac app and web app that feels like a truly great experience
and which builds on all recent feedback and progress."

## Line width

The reader's text column had one measure: the bundle's CSS caps the body at `min(72ch, 704px)`, so a wider window only
added margins (and, because of the pixel cap, larger text held fewer words a line). There are now three stops, kept per
device (native `reader.lineWidth`, browser `gradstep.reader.lineWidth`):

| Stop | Measure | Use |
|---|---|---|
| Comfortable (default) | 72 characters (no pixel cap: larger text keeps its words) | most reading |
| Wide | 100 characters | wide windows, dense papers |
| Full width | the window, with margins of `clamp(22px, 4vw, 72px)` | "a wider space puts more words on a line" |

- **One implementation**, in the shared reader bridge (`reader-bridge.js`, which the browser build copies):
  `__scienceReaderSetLineWidth(mode)` sets `data-sr-line-width` on the page and a host style. The bundle's CSS and the
  compiler are untouched (bundles are content-addressed; no renderer revision). The first value comes with the page
  (`window.__readerLineWidth`, before the first layout, so a restored place doesn't move); later changes keep the
  paragraph being read at the top (measured before the reflow; after a citation jump the reference stays in view).
- Figures at Wide and Full width stay at most `min(100%, 110ch)` wide and centered; tables and display math already
  scroll inside their own boxes, so nothing scrolls the page sideways at any measure.
- **Where**: native, a menu beside A− / A+ in the wide layout (iPad ≥ 850 pt, Mac; a phone's column is the same at every
  stop), in reading mode's bar, and View › Line Width on the Mac (⌃⌘1, ⌃⌘2, ⌃⌘3); browser, a three-way control beside
  the text size (hidden only below a 560 px paper column), arrow keys move between the stops.

## Reading mode

The paper alone, the app's chrome stepping aside, with everything recent still in reach.

| | Mac | iPad (wide layout) | Browser |
|---|---|---|---|
| Enter | View › Enter Reading Mode (⇧⌘R, as Safari's Reader), the paper bar's book button | the book button, ⇧⌘R on a keyboard | the book button, F |
| Window | real full screen (AppKit's `toggleFullScreen:`); leaving full screen the Mac's way leaves reading mode | status bar hidden | Fullscreen API; refused → the same layout in the window; leaving full screen leaves reading mode |
| Leave | Esc, ⇧⌘R, the bar's ✕ | Esc, the bar's ✕ | Esc, F, the bar's ✕ |
| Hidden | toolbar, view switch, library, chat column, docked player | the same | top bar, side panel, splitters, docked player |
| Restored on exit | the layout as it was (nothing about it changed), windowed unless it was full screen before | the same | the side panels as they were |

- **The quiet bar** over the top of the paper: ✕, Contents, title with the section being read, how far through (and a
  2 pt progress line), Figures, A− / A+, Line width, Ask in chat (Listen, Find and the paper's "…" menu on the browser).
  It shows on entering (so it can be found), when the pointer comes near the top edge or a tap lands there, and stays
  while Back is offered, while the chat is open, while VoiceOver runs, and while a pointer is over it; reading on
  (scrolling) puts it away, as in Books. A tap's bar stays ten seconds so its menus can be used.
- **Keys**: Space / Shift-Space and the arrows scroll the paper (it takes the keyboard on entering); J / K go to the
  next / previous section (also outside reading mode; Paper › Next / Previous Section, ⌥⌘↓ / ⌥⌘↑ on the Mac); ⌘F finds;
  Esc closes the chat, then leaves.
- **Still there**: citation, figure and reference jumps with "Back to {section}" and its ✕ (the bar stays while Back is
  offered), figure reference popovers, the tapped-equation menu (Explain in Chat, the equation view), selection actions,
  passage marks, the figure gallery and Contents.
- **Ask in chat without leaving**: the chat slides over the paper's trailing side (native ⌃⌘H or the bar; browser `]`
  or the bar). It never reflows the paper, so the place stays; the bar keeps clear of it.
- The section shown and J / K come from the reader's position reports for every paper (an arXiv HTML paper too), mapped
  to the bundle's headings (a heading's ID is its block's ID): `ReadingSections`.

## Decisions

- ⇧⌘R, not ⌃⌘F: the system's View › Enter Full Screen keeps ⌃⌘F; reading mode includes full screen.
- Mac full screen goes through AppKit's public `-[NSWindow toggleFullScreen:]` by the runtime (Mac Catalyst has no
  API); nothing private.
- The native key listener (J, K, Esc) is in the native page's own prelude, not the shared bridge: the browser's frame
  shim forwards its own keys, and one listener per surface avoids double steps.
- iPhone keeps its layout: no line-width control or reading mode (its column is already the screen).

## Tests

- Native unit (`ScienceReaderTests/ReadingModeTests`, 6): sections and stepping, the measure kept per device, the bridge
  setter and key script present, entering and leaving (needs a paper; the chat goes with it), J / K from the reported
  place.
- iPad journeys (`ScienceReaderUITests/ReadingModeJourneyTests`, 3, iPad Air 13-inch landscape): the measure widens
  Comfortable → Wide → Full width and back; reading mode shows the paper alone, the bar steps aside and comes back at the
  top edge, the chat slides over without reflowing the paper, the measure from the bar, exit restores the split; dark.
- Mac: compiles for Catalyst (`build-for-testing`); its menus and full screen have no runtime UI test here (Mac UI tests
  need the automation permission on the build machine).
- Browser (`e2e/reading-mode.spec.ts`, desktop): Comfortable is capped and Full width grows with the window, the place is
  kept, arrow keys and memory; reading mode: chrome hidden, the place kept, the bar's hide and return, J / K, Space, an
  in-paper link with Back, the chat over the paper (no reflow), Esc twice, the panels restored, F again.
- Screenshots: `.artifacts/reading-mode/` (web 1440 and 1920 at each stop, reading mode light, dark and with chat; iPad
  landscape at each stop, reading mode on entering, reading, with chat, full width, dark).
