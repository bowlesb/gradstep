# Validation annotations (Claude visual review). Keys are figure ids.
A = {}
NEED = {}  # ids needing a blocks/boxes pass, with reason
def v(i, **k): A[i] = {'label': 'vector', **k}
def g(i, panels, shared=(), note=''): A[i] = {'label': 'vgroup', 'panels': panels, 'shared': list(shared), 'note': note}
# sheet-vector 000
g('2601.21948v2-001', [[6,2,7,3,8,4,9,5,'s1','s2'],[0],[1,'s0']], note='lettered group of 8 axes; (a) letter sits in (b) box')
v('2603.00156v2-000')
NEED['2604.01569v2-001'] = 'infographic: pipeline + pie + two histograms'
g('2605.29350v2-005', [[0],[2,1]], note='(b) covers two bar charts')
g('2609.36375v1-007', [[0],[1,'s0'],[2]], note='rotated y-label marked shared')
v('2610.01257v1-006'); v('2609.11014v1-003')
g('2610.02303v1-015', [[1],[0,'s0']])
g('2610.09941v1-004', [[0,1,'s0'],[4,5,'s1'],[2,3,'s2'],[6,7]], [['s3','s4']], note='lettered columns of 2 axes each')
g('2608.30107v2-007', [[1,'s0'],[0,'s2','s1']], note='panel titles marked shared')
v('2610.02670v1-006', note='figure legend split across (b)/(c)')
v('2608.07029v1-022')
# sheet-vector 001
v('2606.16149v5-003')
g('2605.29350v2-002', [[1],[0,'s0']], note='lettered title marked shared')
v('2610.24818v1-000'); v('2609.32758v1-006')
g('2610.20459v1-001', [[1,'s2','s3'],[0,'s1'],[2]], [['s0']], note='per-panel legends below panels')
v('2610.01257v1-010')
v('2610.19190v1-000', note='shared legend split across panels')
v('2608.07029v1-005')
g('2609.07601v1-004', [[1,'s0'],[0,'s1']], note='panel titles marked shared')
v('2609.37493v1-004', note='shared legend on top')
NEED['2609.00696v2-000'] = 'three scatter/hist panels found as one vector panel'
v('2603.09968v2-005')
# sheet-vector 002
v('2610.25558v1-000'); v('2610.13292v1-010'); v('2609.35738v1-002', note='shared legend on top')
g('2609.22174v1-005', [[1,3,'s1','s0'],[0],[2]], note='(a) = bar chart + upset matrix')
v('2610.08463v1-011', note='shared legend at bottom'); v('2610.14270v1-001'); v('2601.21948v2-004'); v('2610.15915v1-001')
v('2609.35865v1-004'); v('2609.39644v2-022')
g('2608.07713v2-004', [[0],[1,'s0']])
g('2610.11776v1-003', [[0,'s0'],[1,'s2','s1']], note='x-label and title marked shared')
# sheet-vector 003
for i in ['2606.20333v2-002','2610.14731v1-001','2610.06342v1-002','2609.29584v1-006','2610.09941v1-003','2610.15501v1-000',
          '2608.25570v1-001','2609.32758v1-008','2609.39912v1-001','2512.17375v3-004']: v(i)
v('2610.24717v1-004', note='legend split across panels')
v('2608.16377v1-003', note='figure note at bottom shared')
# sheet-vector 004
g('2608.30107v2-003', [[1,'s0'],[0,'s2','s1']], note='panel titles marked shared')
for i in ['2309.06349v2-001','2608.08244v2-002','2607.17138v2-004','2608.15129v2-011','2610.01243v1-004','2309.06349v2-000','2609.01493v2-009','2609.39644v2-013']: v(i)
v('2610.08680v1-003', note='shared legend on top'); v('2609.04177v1-005', note='shared title strip')
g('2610.14270v1-000', [[1],[3,'s0'],[5,'s1'],[0,'s2'],[2,'s3'],[4,'s4']], note='panel titles marked shared')
# sheet-vector 005
for i in ['2609.08806v1-004','2609.37447v1-016','2511.19328v3-008','2609.05663v1-005','2608.08541v1-001','2606.25156v4-001',
          '2609.33915v1-014','2603.18908v6-003']: v(i)
v('2608.24189v1-010', note='Top/Bottom rows; each axes titled; ambiguous grouping')
v('2609.03422v1-010', note='legend strips below'); v('2610.25497v1-003', note='shared legend spread under panels')
NEED['2610.02206v1-000'] = 'infographic: pipeline row + five numbered sections'
# sheet-vector 006
g('2609.03106v1-010', [[0,'s0'],[1]], [['s1'],['s3','s4','s5','s2']], note='suptitle + legend between panels')
for i in ['2607.22286v2-012','2607.08837v4-008','2610.15661v1-000','2609.03422v1-009','2608.11242v2-006','2610.05842v1-006']: v(i)
v('2609.11240v1-000', note='image grid without letters = single')
NEED['2608.06933v1-004'] = 'three heatmaps found as one vector panel'
v('2610.13778v1-009', note='shared legend at bottom')
g('2609.17184v1-004', [[0,'s0'],[1,'s1']], note='x tick-label row marked shared')
g('2610.19701v1-009', [[1],[3],[2],[0,'s0']], note='stacked plots; last legend')
# sheet-vector 007
A['2610.02206v1-003'] = {'label': 'single', 'note': 'stacked protocol diagram; vector split stages'}
A['2609.34286v1-002'] = {'label': 'single', 'note': 'image grid without letters; vector split'}
for i in ['2610.04976v1-010','2608.15802v1-000','2607.29398v1-001','2609.04177v1-013','2610.00666v1-014','2610.08630v1-000','2507.03326v1-000']: v(i)
A['2608.02662v1-012'] = {'label': 'exclude', 'reason': 'ambiguous grouping of 12-heatmap grid (rows vs columns)'}
NEED['2608.06933v1-005'] = 'schematic + bar chart in one vector panel'
v('2604.25154v2-005', note='shared legend at bottom')
# sheet-vector 008
v('2511.06391v3-002', note='shared legend at bottom'); v('2608.23161v1-002'); v('2604.14251v2-010')
def b(i, panels, shared=(), note=''): A[i] = {'label': 'boxes', 'panels': panels, 'shared': list(shared), 'note': note}
def s(i, note=''): A[i] = {'label': 'single', 'note': note}
def x(i, reason): A[i] = {'label': 'exclude', 'reason': reason}
# grid 000
b('2606.00435v5-008', [[0,0,.305,.87],[.305,0,.6,.87],[.6,0,1,.87]], [[0,.87,1,1]], 'shared legend under radars')
b('2512.02323v2-009', [[0,0,1,.42],[0,.42,1,1]], note='stacked bar charts, shared x')
b('2603.18893v3-005', [[0,.09,.495,1],[.495,.09,1,1]], [[0,0,1,.09]], 'shared legend on top; narrow gutter')
b('2609.32247v1-005', [[0,0,1,.46],[0,.46,1,1]])
b('2608.30352v1-000', [[0,0,.395,1],[.6,0,1,1]], [[.395,0,.6,1]], 'interface screenshot halves; callouts shared')
b('2605.14698v2-002', [[0,0,.365,.89],[.365,0,.68,1],[.68,0,1,.46],[.68,.46,1,1]], [[0,.89,.36,1]], 'touching panels; legend under A')
# grid 001
b('2609.36375v1-001', [[0,0,.34,1],[.34,0,.705,1],[.68,0,1,1]], note='touching scatter plots; titles overlap neighbours')
b('2605.14698v2-004', [[0,0,.285,1],[.285,0,1,1]], note='bar chart + heatmap table touching')
b('2610.19184v1-000', [[0,0,.445,1],[.47,0,1,1]], [[.445,0,.47,1]], 'two diagram panels with connector arrow')
b('2606.08034v2-002', [[0,0,.637,.655],[.637,0,1,.655],[0,.655,1,1]], note='dashed separators; figure frame')
b('2607.10137v3-006', [[0,.09,.48,1],[.48,.09,1,1]], [[0,0,1,.09]], 'suptitle shared')
b('2603.18893v3-001', [[0,.08,.305,1],[.305,.08,.575,.5],[.305,.5,.575,1],[.575,.08,1,1]], [[0,0,1,.08]], 'lettered groups of small plots; legend on top')
# grid 002
b('2610.18143v1-003', [[.03,.04,.37,.375],[.37,.04,.67,.375],[.67,.04,1,.375],[.03,.5,.37,.84],[.37,.5,.67,.84],[.67,.5,1,.84]],
  [[0,0,1,.04],[0,.375,1,.47],[0,.84,1,.9],[0,.9,1,1],[0,0,.03,1]], 'shaded rows, shared column titles/x-labels/legend')
b('2609.36966v2-007', [[0,0,1,.315],[0,.315,1,.62],[0,.62,1,.955]], [[0,.955,1,1]], 'lettered rows of three plots')
b('2609.34970v1-000', [[0,0,.619,.485],[.619,0,1,.485],[0,.485,.511,1],[.511,.485,1,1]], note='framed diagram panels')
b('2609.23715v1-000', [[0,0,1,.305],[0,.305,1,.626],[0,.626,1,1]], note='two lettered diagrams + unlettered bar chart')
b('2610.04882v1-002', [[0,.045,.497,.5],[.497,.045,1,.5],[0,.5,.497,1],[.497,.5,1,1]], [[0,0,1,.045]], 'legend on top; narrow gutters')
b('2609.03687v1-008', [[0,0,.5,.315],[.5,0,1,.315],[0,.315,.5,.655],[.5,.315,1,.655],[0,.655,.5,1],[.5,.655,1,1]], note='attention heatmap grid with colorbars')
# grid 003
b('2512.03593v2-000', [[0,0,.285,1],[.285,0,1,1]], note='photo panels')
b('2606.00284v2-000', [[0,0,1,.445],[0,.445,1,1]], note='(b) = three bar charts')
b('2608.03085v1-005', [[0,0,1,.47],[0,.47,1,1]], note='lettered rows of three scatter plots')
b('2609.36218v1-004', [[0,0,.585,1],[.565,0,1,1]], note='touching charts; overlapping extents')
b('2608.11738v1-003', [[0,0,.26,1],[.26,0,1,.24],[.26,.24,.648,1],[.648,.24,1,1]], note='framed pipeline panels')
b('2610.04882v1-004', [[0,0,.49,1],[.49,0,1,1]])
# grid 004
b('2609.22174v1-000', [[0,0,1,.405],[0,.405,1,1]], note='stacked diagrams')
b('2608.08354v2-001', [[0,.06,1,.226],[0,.226,1,.428],[0,.428,1,.6],[0,.6,1,.785],[0,.785,1,1]], [[0,0,1,.06]], 'lettered rows of image grid; narrow gaps; shared column headers')
b('2512.02323v2-000', [[0,0,.23,.428],[.23,0,.477,.428],[.477,0,.737,.428],[.737,0,1,.428],[0,.428,.612,1],[.612,.428,1,1]], note='framed diagram panels')
b('2609.11014v1-000', [[0,0,.225,1],[.24,0,.465,1],[.475,0,.765,1],[.75,0,1,1]], [[.225,.3,.24,.7],[.465,.3,.475,.7]], 'panels with arrows between')
b('2610.20960v1-001', [[0,0,1,.455],[0,.455,.486,.91],[.486,.455,1,.91]], [[0,.91,1,1]], 'dense diagram; connectors cross panels')
b('2610.23263v1-008', [[0,.04,.5,1],[.5,.04,1,1]], [[0,0,1,.04]], 'two photos with shared prompt')
# grid 005
b('2608.29426v1-005', [[0,0,.49,.465],[.49,0,1,.465],[0,.465,.49,.915],[.49,.465,1,.915]], [[0,.915,1,1]], 'legend at bottom')
b('2608.15022v1-002', [[0,0,.467,1],[.467,0,1,1]], note='narrow gutter')
b('2610.04976v1-001', [[0,.09,.425,1],[.425,.09,.7,1],[.7,.09,1,1]], [[0,0,1,.09]], 'legend on top; touching bar charts')
b('2605.17990v2-008', [[0,0,.652,1],[.652,0,1,1]], note='(a) = two heatmaps; (b) = photos')
b('2609.33601v1-005', [[0,0,.44,1],[.445,0,1,1]], [[.44,0,.445,1]], 'two image grids split by dashed line')
b('2610.02180v1-008', [[0,0,1,.3],[0,.3,1,.618],[0,.618,1,1]], note='lettered rows of touching image strips')
# grid 006
b('2604.18484v2-000', [[0,0,.43,.41],[0,.41,.43,1],[.435,0,1,1]], note='dashed separators')
b('2609.29584v1-009', [[0,0,.55,.62],[.55,0,1,.62],[0,.62,1,1]], note='table + chart + summary cards')
b('2608.16831v2-000', [[0,0,.356,.66],[.356,0,1,.66],[0,.66,1,1]], note='framed panels; third panel C unlisted in caption parse')
b('2608.00657v1-004', [[0,0,.35,1],[.33,0,.665,1],[.645,0,1,1]], note='touching heatmaps with colorbars')
b('2608.18921v1-004', [[0,0,.18,1],[.218,0,.5,1],[.54,0,.74,1],[.775,0,1,1]], [[.18,.3,.218,.7],[.5,.3,.54,.7],[.74,.3,.775,.7]], 'pipeline stages with arrows; tinted background')
b('2610.25877v1-003', [[0,0,.378,1],[.378,0,.73,1],[.73,0,1,1]], note='text panels + plot')
# grid 007
b('2609.37493v1-003', [[0,0,.335,1],[.335,0,.612,1],[.612,0,1,1]], note='raster charts, narrow gutters')
b('2609.18163v1-001', [[0,0,.348,1],[.348,0,.665,1],[.665,0,1,1]], note='ROC panels with insets')
b('2609.33618v1-000', [[0,0,.483,1],[.483,0,1,1]], note='diagram + scatter')
b('2610.06729v2-008', [[0,.12,.505,1],[.505,.12,1,1]], [[0,0,1,.12]], 'legend on top')
b('2505.12576v3-014', [[0,0,.372,1],[.372,0,.697,1],[.697,0,1,1]])
b('2608.19875v1-000', [[0,0,1,.4],[0,.4,1,1]], note='stacked diagrams')
# grid 008
b('2610.08829v1-002', [[0,0,.5,.795],[.5,0,1,.795]], [[0,.795,1,1]], 'legend under both')
b('2610.09239v1-003', [[0,0,.19,1],[.19,0,.358,1],[.358,0,.518,1],[.518,0,.685,1],[.685,0,1,1]], note='five raster plots in a row')
b('2610.06269v1-010', [[0,0,.495,1],[.495,0,1,1]], note='two flow diagrams')
s('2610.08954v1-002', note='connected pipeline with lettered stages = single')
b('2610.02162v1-001', [[0,0,1,.245],[0,.245,1,.49],[0,.49,1,.735],[0,.735,1,1]], note='lettered rows of frame strips; figure frame')
b('2607.10137v3-004', [[0,.05,.49,1],[.49,.05,1,1]], [[0,0,1,.05]], 'suptitle shared')
# grid 009
b('2610.12299v1-000', [[0,0,1,.46],[0,.46,1,1]], note='lettered rows: inputs (three sub-groups) + video frames')
b('2608.18607v4-000', [[0,0,.427,1],[.427,0,1,.373],[.427,.373,1,1]], note='dashed frames')
b('2610.26749v1-012', [[0,.05,1,.525],[0,.525,1,1]], [[0,0,1,.05]], 'lettered rows of plots; legend on top')
b('2609.07601v1-002', [[0,0,.35,.48],[.35,0,1,.48],[0,.48,.32,1],[.32,.48,.64,1],[.64,.48,1,1]], note='five raster charts')
b('2610.08967v1-000', [[0,0,.312,1],[.335,0,.632,1],[.645,0,1,1]], [[.312,.3,.335,.7],[.632,.3,.645,.7]], 'framed panels with arrows')
b('2609.16841v1-001', [[0,0,.615,1],[.615,0,1,1]], note='two diagram panels')
# grid 010
b('2607.28678v1-001', [[0,0,.328,1],[.328,0,.67,1],[.67,0,1,1]], note='three framed stages with arrows crossing frames')
b('2608.18746v1-000', [[0,0,.49,1],[.49,0,1,1]], note='schematic panels')
b('2610.24521v1-002', [[0,0,1,.31],[0,.31,1,1]], note='top/bottom sections, each a grid of small plots')
s('2608.30865v1-001'); s('2608.04576v1-003', note='word cloud')
b('2607.18255v2-012', [[0,0,.5,1],[.5,0,1,1]], note='left/right raster plots')
# grid 011
s('2605.21600v3-000', 'architecture diagram'); s('2507.07426v4-003', 'tree diagram'); s('2502.02542v5-005', 'text document image')
s('2610.06919v1-004'); s('2608.20348v1-001')
b('2608.00657v1-005', [[0,0,.49,1],[.49,0,1,1]])
# grid 012
b('2609.09076v1-001', [[0,0,.245,1],[.245,0,.48,1],[.48,0,.717,1],[.717,0,1,1]], note='four numbered framed stages')
s('2609.29056v1-007')
s('2610.13316v1-002', 'titled example gallery (8 categories); ambiguous')
s('2604.08547v2-009', 'image grid'); s('2610.05954v1-024', 'image grid'); s('2608.10411v2-012', 'image grid with column headers')
# grid 013
s('2608.04525v1-012', 'image grid'); s('2608.15583v1-001', 'image grid')
b('2507.06061v2-004', [[0,0,1,.37],[0,.37,1,.68],[0,.68,1,1]], [[.25,0,1,.065]], 'stacked lettered charts; legend beside letter A')
s('2609.14466v1-003', 'image grid'); s('2608.15905v2-000', 'titled clip grid telling one story')
b('2508.06659v2-001', [[0,0,.3,.455],[.3,0,.585,.455],[.585,0,.862,.455],[0,.455,.3,1],[.3,.455,.585,1],[.585,.455,.862,1]], [[.862,0,1,1]], 'small raster plot grid, legend at right')
# grid 014
s('2609.03464v1-001', 'pipeline'); s('2609.37458v1-000', 'pipeline'); s('2609.29056v1-004')
x('2608.28924v1-004', 'ambiguous 4x3 facet grid (rows vs columns vs cells)')
b('2607.28934v2-004', [[0,0,.397,.885],[.397,0,.697,.885],[.697,0,1,.885]], [[0,.885,1,1]], 'touching facets, shared y-axis and legend')
s('2610.03252v1-014', 'image grid with captions')
# grid 015
b('2602.00884v2-000', [[0,0,.47,1],[.47,0,1,1]], note='left/right diagram panels')
b('2512.21113v2-015', [[0,0,.196,1],[.196,0,.41,1],[.41,0,.6,1],[.6,0,.797,1],[.797,0,1,1]], note='five small raster plots, narrow gutters')
b('2606.25156v4-000', [[0,.08,.505,1],[.505,.08,1,1]], [[0,0,1,.08]], 'legend on top')
b('2606.00367v2-006', [[0,0,.255,.32],[.255,0,.503,.32],[.503,0,.755,.32],[.755,0,1,.32],[0,.32,.255,.655],[.255,.32,.503,.655],[.503,.32,.755,.655],[.755,.32,1,.655],[0,.655,.255,1],[.255,.655,.503,1],[.503,.655,.755,1]], [[.755,.655,1,1]], '11 titled raster plots + legend cell')
b('2609.03442v1-001', [[0,0,.315,1],[.315,0,.632,1],[.632,0,1,1]], note='three raster plots')
s('2606.25836v3-005', 'text screenshot')
# grid 016
b('2608.24758v2-002', [[0,0,.5,.87],[.5,0,1,.87]], [[0,.87,1,1]], 'two titled domains, each radar pair + bars; legend at bottom')
b('2609.34513v1-006', [[0,0,1,.305],[0,.305,1,1]], note='x-ray row + spreadsheet screenshot')
s('2606.00299v2-006', 'image grid')
b('2609.12364v1-004', [[0,0,.32,1],[.32,0,.665,1],[.665,0,1,1]], note='three dark UI screenshots')
b('2606.19370v2-004', [[0,0,.317,1],[.317,0,.66,1],[.66,0,1,1]], note='left/center/right plots')
s('2601.06536v3-005')
# grid 017
b('2605.13088v2-001', [[0,0,.115,1],[.115,0,.447,1],[.447,0,.592,1],[.592,0,.823,1],[.823,0,1,1]], note='five numbered framed workflow stages with arrows')
s('2610.23445v1-024', 'grid-world rendering')
b('2610.06580v1-003', [[0,0,.322,.9],[.322,0,.652,.9],[.652,0,1,.9]], [[0,.9,1,1]], 'left/middle/right groups of 4 small plots; legend at bottom')
s('2608.06956v1-017', 'molecule sequence gallery')
b('2608.01825v1-000', [[0,0,.374,1],[.374,0,.687,1],[.687,0,1,1]], note='three touching renders')
b('2610.02180v1-001', [[0,0,.505,1],[.505,0,1,1]], note='baseline vs ours halves, each control + frames')
# grid 018
s('2608.07713v2-000', 'image grid')
b('2608.24044v3-007', [[0,.025,1,.335],[0,.335,1,.645],[0,.645,1,1]], [[0,0,1,.025]], 'three named scenarios, each two image rows + goal')
s('2605.02849v3-011', 'UI screenshot')
b('2610.11060v1-003', [[0,0,.52,1],[.52,0,1,1]], note='two image columns with own legends')
b('2506.01928v5-007', [[0,0,.505,1],[.505,0,1,1]], note='before/after matrices; sort arrow inside right box')
b('2610.26370v1-001', [[0,0,.448,.457],[.448,0,1,.457],[0,.457,.69,1]], [[.69,.457,1,1]], 'three framed roman-numbered levels + legend')
# grid 019
_c = [0, .281, .518, .757, 1]; _r = [.06, .343, .627, .93]
b('2610.26407v1-022', [[_c[j], _r[i], _c[j+1], _r[i+1]] for i in range(3) for j in range(4)], [[0,0,1,.06],[0,.93,1,1]], '3x4 titled small-plot grid, touching; legend and x-label shared')
b('2506.18203v3-013', [[0,.045,.5,.49],[.5,.045,1,.49],[0,.49,.5,1],[.5,.49,1,1]], [[0,0,1,.045]], 'suptitle + 2x2 titled heatmaps')
b('2610.13834v1-002', [[0,.08,.3,.86],[.3,.08,.535,.86],[.535,.08,.772,.86],[.772,.08,1,.86]], [[0,0,1,.08],[0,.86,1,1]], 'four touching small plots; legend and x-label shared')
b('2609.37115v1-001', [[0,0,.244,1],[.244,0,.434,1],[.434,0,.792,1],[.792,0,1,1]], note='four numbered framed stages with arrows')
s('2608.08964v1-001'); s('2609.14168v1-017', 'text prompt')
# grid 020
s('2607.14345v4-051')
b('2605.09867v2-016', [[0,0,.233,1],[.233,0,.458,1],[.458,0,.684,1],[.684,0,.912,1]], [[.912,0,1,1]], 'four touching titled heatmaps + shared colorbar')
b('2609.34715v1-009', [[0,.1,.915,.52],[0,.52,.915,1]], [[0,0,1,.1],[.915,0,1,1]], 'ID/OOD rows of frames; shared colorbar')
s('2506.01928v5-000', 'feature table diagram')
b('2609.37525v1-000', [[0,0,.45,1],[.45,0,1,1]], note='left/right circuit diagrams with zoom lines')
b('2610.00582v1-001', [[0,0,.262,.8],[.262,0,.526,.8],[.526,0,.781,.8],[.781,0,1,.8],[0,.8,.503,1],[.503,.8,1,1]], note='four numbered stage columns + two application strips')
# grid 021
s('2501.02406v6-004', 'UI screenshot')
b('2608.05877v1-005', [[0,0,.52,1],[.52,0,1,1]], note='two box-plot panels')
s('2609.30572v1-001'); s('2610.10398v1-011', 'image grid with colorbars'); s('2604.11788v2-000', 'pipeline')
b('2606.00435v5-024', [[0,.07,.495,1],[.495,.07,1,1]], [[0,0,1,.07]], 'suptitle shared; touching plots')
# grid 022
b('2610.06936v1-002', [[0,0,.5,.345],[.5,0,1,.345],[0,.345,.495,1],[.495,.345,1,1]], note='printed letters a)-d); line plots + heatmaps')
b('2609.12791v1-000', [[0,0,.418,.275],[.418,0,1,.275],[0,.275,.418,.565],[.418,.275,1,.565],[0,.565,.418,.865],[.418,.565,1,.865]], [[0,.865,1,1]], 'six framed graph diagrams with captions; legend at bottom')
b('2610.04437v1-009', [[0,.05,.194,1],[.194,.05,.389,1],[.389,.05,.591,1],[.591,.05,.79,1],[.79,.05,1,1]], [[0,0,1,.05]], 'five touching small bar charts; legend on top')
s('2603.28662v2-013'); s('2608.06671v1-001'); s('2608.01730v1-001')
# grid 023
b('2608.06396v1-000', [[.075,0,.565,.435],[.565,0,1,.435],[.075,.435,.565,.93],[.565,.435,1,.93]], [[0,0,.075,.93],[0,.93,1,1]], 'touching 2x2 scatter grid with shared axis labels')
s('2601.12758v2-000', 'connected architecture'); s('2608.29346v1-007', 'image strip')
# need sheet
b('2604.01569v2-001', [[0,0,.69,.7],[.69,0,1,.7],[0,.7,.505,1],[.505,.7,1,1]], note='infographic: connected pipeline + pie + two histograms')
b('2609.00696v2-000', [[0,0,.52,.49],[.52,0,1,.49],[0,.49,1,1]], note='vector found one panel; three lettered panels')
b('2610.02206v1-000', [[0,0,1,.32],[0,.32,1,1]], note='workflow strip + framed benchmark summary; hierarchy ambiguous')
b('2608.06933v1-004', [[0,.03,.39,1],[.39,.03,.69,1],[.69,.03,1,1]], [[0,0,1,.03]], 'three heatmaps found as one vector panel')
b('2608.06933v1-005', [[0,.05,.3,1],[.3,.05,1,1]], [[0,0,1,.05]], 'schematic + bar chart in one vector panel')
for k in list(NEED):
    assert k in A, k
# GT review fixes
b('2606.00435v5-008', [[0,0,.305,.935],[.305,0,.6,.935],[.6,0,1,.935]], [[0,.935,1,1]], 'shared legend under radars; two-line panel captions')
b('2610.18143v1-003', [[.03,.04,.37,.405],[.37,.04,.67,.405],[.67,.04,1,.405],[.03,.5,.37,.885],[.37,.5,.67,.885],[.67,.5,1,.885]],
  [[0,0,1,.04],[0,.405,1,.47],[0,.885,1,.94],[0,.94,1,1],[0,0,.03,1]], 'shaded rows, shared column titles/x-labels/legend')
b('2610.04976v1-001', [[0,.09,.425,1],[.425,.09,.708,1],[.695,.09,1,1]], [[0,0,1,.09]], 'legend on top; touching bar charts; rotated labels overlap')
