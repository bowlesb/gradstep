A = {}; NEED = {}
def v(i, c='plot-grid', note=''): A[i] = {'label': 'vector', 'note': f'class={c}; {note}'}
def g(i, panels, shared=(), c='plot-grid', note=''): A[i] = {'label': 'vgroup', 'panels': panels, 'shared': [[t] if isinstance(t, str) else t for t in shared], 'note': f'class={c}; {note}'}
def b(i, panels, shared=(), c='plot-grid', note=''): A[i] = {'label': 'boxes', 'panels': panels, 'shared': list(shared), 'note': f'class={c}; {note}'}
def s(i, note=''): A[i] = {'label': 'single', 'note': note}
def x(i, reason): A[i] = {'label': 'exclude', 'reason': reason}
# vector 000
v('2609.35823v1-003'); v('2609.34212v1-004')
g('2609.09989v1-006', [[0,'s2'],[1,'s0'],[2,'s1']], note='x-labels marked shared')
v('2609.33169v2-006'); v('2610.06204v1-002'); v('2610.14376v1-000'); v('2605.01632v2-002'); v('2608.23526v1-002', note='legend at bottom shared')
v('2609.13345v1-011'); v('2510.14217v3-004')
NEED['2609.26063v1-001'] = 'two panels found as one'
NEED['2608.03967v1-006'] = 'c,d,e merged'
# vector 001
v('2602.08751v4-005')
NEED['2609.32528v1-000'] = 'framed sections found as one'
g('2609.16540v1-001', [[2],[0,'s0'],[1]], note='letter b marked shared')
v('2609.25827v1-001')
g('2610.15778v1-002', [[1],[0,'s0']], note='letter marked shared')
v('2606.02363v2-004'); v('2610.20947v1-001'); v('2608.28922v1-000')
v('2505.09496v4-000', c='many-panels', note='a,b,c are x categories; 6 unlettered axes; legend shared')
v('2604.21375v3-000'); v('2606.02363v2-005')
NEED['2609.09899v1-003'] = 'heatmaps found as one'
# vector 002
NEED['2610.26840v1-000'] = 'a+b diagrams and c+d plots merged'
s('2610.13238v1-005', 'one axes despite caption letters')
g('2608.04962v2-001', [[2,3,'s1','s2','s0'],[1],[0]], c='lettered-plot-groups', note='(a) = upper+lower plot')
v('2605.27901v2-011', note='legend shared'); v('2607.06640v2-007'); v('2609.03331v1-006'); v('2609.13345v1-013')
NEED['2610.25128v1-001'] = 'a scatter + b violins merged'
g('2607.26924v3-001', [[1],[0],[2,3]], c='lettered-plot-groups', note='(c) has two axes')
v('2610.09202v1-002'); v('2609.02679v3-011')
g('2610.09118v1-000', [[0],[1],[2,'s1'],[3,'s0']], c='framed-diagrams', note='titles marked shared')
# vector 003
v('2610.06986v1-009'); v('2605.20854v3-002'); v('2608.23526v1-000'); v('2610.20947v1-000', note='x-label shared')
v('2607.26924v3-002'); v('2609.25827v1-000')
g('2610.02835v1-003', [[0,'s0'],[1]], note='y-label marked shared')
g('2511.16839v4-003', [[2,'s0'],[3,'s1'],[0,'s2'],[4,'s4','s3'],[5,'s6','s5'],[1,'s8','s7']], c='many-panels', note='titles/x-labels per panel; legends shared')
v('2605.10828v2-001', note='legend strip shared')
g('2610.21218v1-004', [[0,'s0'],[1,'s1'],[3,'s2'],[2],[4,'s3'],[5,'s4'],[6,'s5']], c='many-panels', note='titles marked shared; legend cell shared')
s('2610.02199v2-002', 'one axes with mirrored bars'); s('2601.00290v3-002')
# vector 004
s('2609.33670v1-006', 'broken-axis single plot')
v('2609.27035v2-001')
g('2410.01917v3-000', [[1,'s4','s5'],[2,'s0','s1'],[0,'s2','s3']], note='per-panel legends below')
s('2606.21155v3-002'); v('2610.01096v1-003', note='legend shared'); s('2610.25501v1-005', 'flow diagram')
NEED['2610.12464v1-000'] = 'Left plot + Right image grid as one'
s('2609.33670v1-001', 'pipeline in one frame')
v('2511.16839v4-013'); s('2610.13479v1-017'); v('2605.08583v3-003', note='legend fragments shared'); s('2610.00002v1-001')
# vector 005
v('2610.10636v1-003'); s('2610.16661v1-006'); v('2508.16085v2-023', c='many-panels'); s('2610.21919v1-009'); s('2606.00151v2-013')
s('2606.26618v2-000', 'pipeline'); s('2602.02326v3-002', 'dendrogram')
NEED['2610.09070v1-000'] = '6 titled heatmaps found as one'
s('2606.31282v2-004'); s('2608.04549v2-008'); s('2608.14446v1-006'); s('2609.17211v1-001', 'connected pipeline')
# vector 006
s('2604.12335v2-002', 'annotation table image'); v('2609.03694v1-003')
g('2610.01355v1-003', [[2,'s4','s5'],[0,'s6','s7','s0'],[3,'s1'],[1,'s2','s8','s9']], ['s3'], note='titles/legends per panel; suptitle shared')
s('2609.15239v1-000', 'connected pipeline with feedback arrow'); s('2601.08151v2-012'); v('2610.02126v1-003'); s('2609.07611v1-006')
v('2610.26155v1-006', c='many-panels', note='12 unlettered axes; legend shared'); s('2510.27313v3-003')
# grid 000
b('2610.02835v1-001', [[0,0,.43,1],[.43,0,1,1]], c='other', note='prompt box + plot')
b('2608.16320v1-002', [[0,0,.5,1],[.5,0,1,1]])
b('2610.19254v1-000', [[0,0,.44,1],[.44,0,1,1]], c='framed-diagrams')
b('2609.27306v1-003', [[0,0,.345,1],[.345,0,.695,1],[.695,0,1,1]], c='lettered-plot-groups', note='lettered columns of 2 plots')
b('2609.17211v1-008', [[0,0,.5,.5],[.5,0,1,.5],[0,.5,.5,1],[.5,.5,1,1]], c='touching-raster', note='framed photo-strip panels')
b('2610.15778v1-004', [[0,0,.33,1],[.33,0,.6,1],[.6,0,1,1]])
# grid 001
b('2602.04819v5-003', [[0,0,.795,1],[.795,0,1,1]], c='framed-diagrams', note='dashed frames')
_c=[0,.18,.39,.6,.81,1]; _r=[0,.44,1]
b('2609.21263v1-009', [[_c[j],_r[i],_c[j+1],_r[i+1]] for i in range(2) for j in range(5)], c='many-panels', note='10 lettered layout renders, touching raster')
b('2605.01240v3-005', [[0,0,.4,.47],[.4,0,1,.54],[0,.48,.4,1],[.4,.55,1,1]], note='tick labels overlap next row')
b('2608.14003v1-001', [[0,0,1,.455],[0,.455,1,1]], c='framed-diagrams')
b('2610.04225v1-001', [[0,0,.625,.49],[0,.49,.625,1],[.625,0,1,1]], c='touching-raster')
b('2609.27201v1-000', [[0,0,.44,.43],[.44,0,1,.43],[0,.43,1,1]], c='framed-diagrams')
# grid 002
s('2609.28931v1-002', 'connected overview with zoom lines; letters not printed')
b('2609.15018v2-002', [[0,0,.585,1],[.585,0,1,1]], c='framed-diagrams')
b('2610.26840v1-002', [[0,.06,1,.47],[0,.47,1,1]], [[.58,0,.95,.06]], c='framed-diagrams', note='legend shared')
b('2608.16084v1-003', [[0,0,.455,.515],[.455,0,.93,.515],[0,.515,.455,1],[.455,.515,.93,1]])
b('2609.32275v1-000', [[0,0,.39,.47],[0,.47,.195,1],[.195,.47,.39,1],[.43,0,1,1]], [[.39,.33,.43,.62]], c='framed-diagrams', note='(a)(b)(c) graph diagrams + Right chart; arrow shared')
b('2609.34591v1-002', [[0,.04,.52,1],[.52,.04,1,1]], [[0,0,1,.045]], note='legend on top')
# grid 003
b('2610.01663v2-008', [[0,0,.27,1],[.27,0,.505,1],[.505,0,.74,1],[.74,0,1,1]], c='touching-raster', note='protein renders with captions')
b('2609.16551v1-001', [[0,.07,.395,1],[.395,.07,.7,1],[.7,.07,1,1]], [[0,0,1,.07]], note='legend on top')
b('2610.03039v1-000', [[0,0,1,.3],[0,.3,1,.62],[0,.62,1,1]], c='framed-diagrams')
b('2609.06873v1-005', [[0,.06,.53,.445],[.53,.06,1,.445],[0,.445,.53,1],[.53,.445,1,.92]], [[0,0,.6,.06]], note='(d) two subplots; title shared')
b('2602.08751v4-004', [[0,0,1,.45],[0,.45,1,1]], c='lettered-plot-groups', note='A = 8 bar charts')
b('2608.07228v1-001', [[0,0,.37,1],[.37,0,.67,1],[.67,0,1,1]])
# grid 004
b('2609.36693v1-001', [[0,0,.335,1],[.335,0,1,1]], c='framed-diagrams')
b('2609.30906v1-000', [[0,0,1,.3],[0,.3,1,1]], c='framed-diagrams', note='dashed separator')
b('2602.01257v2-005', [[0,0,.5,1],[.5,0,1,1]], c='other', note='frame strip + timelines')
_c=[0,.33,.665,1]; _r=[0,.47,1]
b('2603.29135v3-009', [[_c[j],_r[i],_c[j+1],_r[i+1]] for i in range(2) for j in range(3)], c='many-panels', note='6 lettered heatmaps')
b('2603.29135v3-011', [[0,0,1,.36],[0,.36,1,.6],[0,.6,1,1]], c='framed-diagrams', note='arrow from a into b')
s('2610.24812v1-000', 'connected pipeline strip with lettered stages')
# grid 005
s('2608.25623v1-017', 'one axes lollipop chart')
b('2609.16540v1-002', [[0,0,1,.29],[0,.29,.69,.65],[.69,.29,1,.65],[0,.65,.69,1]], [[.69,.65,1,1]], c='lettered-plot-groups', note='b and c are pairs of plots; legend shared')
b('2608.01271v1-007', [[0,.06,.52,1],[.52,.06,1,1]], [[0,0,1,.06]], note='legend on top')
b('2605.01240v3-004', [[0,0,.25,.92],[.25,0,.5,.92],[.5,0,.765,.92],[.765,0,1,.92]], [[0,.92,.5,1],[.5,.92,1,1]], c='touching-raster', note='dataset group labels shared')
b('2608.23719v1-000', [[0,0,.3,1],[.3,0,.69,1],[.69,0,1,1]], c='framed-diagrams')
b('2610.10314v1-000', [[0,0,.335,1],[.335,0,.63,1],[.63,0,1,.55],[.63,.55,1,1]], c='framed-diagrams', note='dashed frames, renders')
# grid 006
b('2609.06873v1-002', [[0,0,.545,.82],[.545,0,1,.82]], [[0,.82,1,1]], note='x-label and legend shared')
b('2511.18191v2-000', [[0,0,1,.29],[0,.29,1,.67],[0,.67,1,.92]], [[0,.92,1,1]], c='framed-diagrams', note='legend shared')
b('2609.27306v1-002', [[0,0,.5,1],[.5,0,1,1]])
b('2609.03690v1-002', [[0,0,.55,.48],[.55,0,1,.48],[0,.48,.55,1],[.55,.48,1,1]], c='framed-diagrams', note='framed charts/table')
b('2604.22825v2-003', [[0,0,.39,.92],[.39,0,.7,.92],[.7,0,1,.92]], [[.6,.92,1,1]], note='legend shared')
b('2607.13688v2-001', [[0,0,.24,1],[.24,0,.485,1],[.485,0,.64,1],[.64,0,.825,1],[.825,0,1,1]], c='touching-raster', note='5 lettered photos')
# grid 007
b('2610.25621v1-000', [[0,0,.34,1],[.34,0,.69,1],[.69,0,1,1]], c='other', note='unframed diagram parts')
b('2610.11264v1-000', [[0,0,.47,.58],[.47,.04,1,.58],[0,.58,1,1]], [[.47,0,.85,.04]], c='framed-diagrams', note='flow legend shared')
b('2609.26063v1-004', [[0,.07,.25,1],[.25,.07,.5,1],[.5,.07,.75,1],[.75,.07,1,1]], [[0,0,1,.07]], note='legend on top')
b('2610.23617v1-000', [[0,0,.225,1],[.225,0,.7,1],[.7,0,1,1]], c='framed-diagrams', note='arrow from a into b')
b('2608.10864v2-000', [[0,0,.49,1],[.49,.03,1,1]], note='(a) three bar groups in one panel')
x('2608.15763v5-000', 'live-room image spans both lettered parts; no clean split')
# grid 008
b('2509.24560v2-000', [[0,0,1,.205],[0,.205,1,1]], c='framed-diagrams', note='dashed separator')
b('2610.12464v1-008', [[0,0,1,.36],[0,.4,.5,.72],[.5,.4,1,.72],[0,.72,.5,1],[.5,.72,1,1]], [[0,.36,.2,.4]], c='touching-raster', note='5 lettered video-frame panels; Failures header shared')
b('2604.22875v3-002', [[0,0,.48,1],[.48,0,1,1]], c='framed-diagrams', note='arrow between')
b('2602.01257v2-006', [[0,0,1,.52],[0,.52,1,1]], c='other', note='frame strip + timeline')
b('2608.18498v1-005', [[0,0,.72,1],[.72,0,1,1]], c='other', note='render grid + zoom views')
b('2604.02794v2-001', [[0,0,1,.5],[0,.5,.71,1],[.71,.5,1,1]], c='framed-diagrams', note='arrow from A into B')
# grid 009
b('2608.04655v1-000', [[0,.21,.47,.6],[.5,.21,1,.6],[0,.6,.47,1],[.5,.6,1,1]], [[0,0,1,.21]], c='touching-raster', note='text prompt shared; 4 lettered images')
b('2608.29903v1-009', [[0,0,.46,.5],[.46,0,.92,.5],[0,.5,.46,1],[.46,.5,.92,1]], [[.92,.2,1,.9]], c='plot-grid', note='heatmaps; shared colorbar and x-label')
b('2608.07228v1-002', [[0,0,.5,1],[.5,0,1,1]])
b('2608.24136v2-000', [[0,0,.41,1],[.41,0,1,1]], c='framed-diagrams', note='dashed separator')
b('2605.29055v2-009', [[0,.03,.5,.5],[.5,.03,1,.5],[0,.5,.5,1],[.5,.5,1,1]], [[0,0,1,.03]], note='suptitle shared')
b('2608.16084v1-007', [[0,0,1,.5],[0,.5,.5,1],[.5,.5,1,1]])
# grid 010
b('2610.18789v1-000', [[0,0,.29,1],[.29,0,.53,1],[.53,0,.77,1],[.77,0,1,1]])
b('2603.14023v3-015', [[0,0,.48,.5],[.48,0,.73,.5],[.73,0,1,.5],[0,.5,.52,1],[.52,.5,1,1]], c='many-panels', note='5 lettered plots')
b('2609.36693v1-002', [[0,0,1,.58],[0,.58,.25,1],[.25,.58,1,1]], c='framed-diagrams')
b('2604.22099v3-000', [[0,0,.5,.49],[.5,0,1,.49],[0,.49,.5,1],[.5,.49,1,1]])
b('2604.22875v3-000', [[0,0,.255,1],[.255,0,1,1]], c='framed-diagrams', note='dashed separator')
b('2606.19990v3-000', [[0,0,1,.27],[0,.27,1,.5],[0,.5,1,.75],[0,.75,1,1]], c='touching-raster', note='lettered rows of video frames + callouts')
# grid 011
s('2610.25781v1-000', 'one render; caption letters refer to other files')
b('2608.12117v1-000', [[0,0,1,.33],[0,.33,1,1]], c='framed-diagrams')
b('2603.25860v4-001', [[0,0,.35,1],[.35,0,.67,1],[.67,0,1,1]], c='framed-diagrams')
b('2609.31114v1-000', [[0,0,.25,1],[.25,0,.5,1],[.5,0,.75,1],[.75,0,1,1]], c='other', note='strip of 4 lettered stages')
b('2502.13141v2-000', [[0,0,.34,1],[.34,0,.67,1],[.67,0,1,1]], c='framed-diagrams', note='dashed separators')
s('2603.23478v2-000', 'one comparison overview; top/bottom are not lettered parts')
# grid 012
b('2609.11201v1-002', [[0,0,1,.465],[0,.465,.48,.74],[.48,.465,1,.74],[0,.74,1,1]], c='framed-diagrams')
b('2608.24460v1-000', [[0,0,.585,1],[.585,0,1,1]])
b('2608.16320v1-005', [[0,0,.5,1],[.5,0,1,1]])
b('2602.02326v3-000', [[0,0,.52,.68],[.52,0,1,.68],[0,.7,1,1]], c='framed-diagrams')
b('2608.26956v2-000', [[0,0,1,.5],[0,.5,1,1]], c='framed-diagrams', note='dashed separator')
b('2609.06261v1-008', [[0,0,.49,1],[.49,0,1,.73],[.49,.73,1,1]], c='touching-raster', note='photos with captions')
# grid 013
b('2608.03967v1-004', [[0,0,.49,1],[.49,0,1,1]], c='other', note='two diagrams split by thin line')
b('2609.32056v1-000', [[0,0,1,.36],[0,.36,1,1]], c='framed-diagrams')
b('2610.10314v1-004', [[0,0,1,.36],[0,.36,1,.64],[0,.64,1,1]], c='lettered-plot-groups', note='each row = 3 plots; legend on top shared')
s('2608.20428v1-003', 'lattice diagram'); b('2607.02486v2-002', [[0,0,.29,1],[.29,0,.56,1],[.56,0,.8,1]], [[.8,.1,1,.5]], note='legend shared')
s('2609.04009v1-001', 'pipeline with two stage frames')
# grid 014
s('2610.03136v1-002', 'connected architecture')
_c=[0,.36,.69,1]; _r=[.06,.36,.68,1]
b('2506.11869v3-007', [[_c[j],_r[i],_c[j+1],_r[i+1]] for i in range(3) for j in range(3)], [[.38,0,.62,.06]], c='many-panels', note='9 unlettered titled bar charts; legend shared')
b('2608.21504v1-002', [[0,.06,.39,1],[.39,.06,.69,1],[.69,.06,1,1]], [[.1,0,.6,.06]], note='touching panels sharing y labels on first')
b('2605.24856v2-000', [[0,0,.5,1],[.5,0,1,1]])
b('2604.01170v2-000', [[0,0,.56,1],[.56,0,1,1]], c='framed-diagrams', note='two phase frames')
b('2606.25108v2-001', [[0,0,1,.45],[0,.45,1,.92]], [[0,.92,1,1]], note='top/bottom titled, shared x-axis and legend')
# grid 015
s('2608.05258v1-002', 'unlettered Grad-CAM image grid')
b('2610.07006v1-000', [[0,0,.5,1],[.5,0,1,1]], c='other', note='Left diagram + Right plot')
s('2609.14207v1-015'); b('2609.04009v1-005', [[0,0,.335,1],[.335,0,.665,1],[.665,0,1,1]], note='three titled loss plots')
s('2609.18260v1-001'); s('2607.28906v1-001', 'numbered stages of one pipeline with arrows')
# grid 016
b('2610.05382v1-000', [[0,0,.5,.41],[0,.41,.5,1],[.5,0,1,1]], c='framed-diagrams', note='left top + radar + right pipeline/plot; ambiguous connectors')
s('2610.14253v1-003', 'unlettered example rows with captions')
x('2602.06886v5-008', 'more than 12 panels (36 layer scatter plots)')
b('2603.02270v2-007', [[0,0,.25,.5],[.25,0,.5,.5],[.5,0,.75,.5],[.75,0,1,.5],[0,.5,.25,1],[.25,.5,.5,1],[.5,.5,.75,1],[.75,.5,1,1]], c='many-panels', note='8 titled t-SNE plots')
s('2608.18131v1-005'); s('2607.14246v2-002')
# grid 017
b('2607.26504v2-000', [[0,0,.385,1],[.385,0,1,1]], c='framed-diagrams', note='Expectation vs Solutions columns')
s('2607.14246v2-000'); s('2608.08632v1-000', 'workflow pipeline'); s('2608.20255v1-002', 'tree diagram'); s('2609.06444v3-002'); s('2605.28008v2-007', 'equation illustration')
# grid 018
s('2606.14741v2-000', 'flowchart')
b('2609.39300v1-001', [[0,0,.505,1],[.505,0,1,1]], c='touching-raster', note='two touching unlettered photos')
b('2610.07646v1-010', [[0,0,.25,1],[.25,0,.495,1],[.495,0,.745,1],[.745,0,1,1]], c='other', note='4 titled framed samples')
b('2609.14654v1-006', [[0,.04,.5,.51],[.5,.04,1,.51],[0,.51,.5,.95],[.5,.51,1,.95]], [[.3,0,.7,.04],[.3,.95,.7,1]], note='4 titled bar charts; legends shared')
s('2610.16338v1-000', 'sunburst with callouts'); s('2606.31981v2-000', 'pipeline overview with photo groups')
# grid 019
s('2509.26087v5-005', 'unlettered top/bottom render grid')
b('2609.24352v1-014', [[0,0,.2,.82],[.2,0,.4,.82],[.4,0,.6,.82],[.6,0,.8,.82],[.8,0,1,.82]], [[0,.82,1,1]], c='many-panels', note='5 titled small plots; x-label and legend shared')
s('2610.14376v1-001'); s('2505.16941v4-006')
b('2608.03291v1-008', [[0,.08,.54,1],[.54,.08,1,1]], [[.3,0,.7,.08]], note='suptitle shared')
s('2609.30391v1-004')
# grid 020
b('2608.25623v1-011', [[0,0,.375,.5],[.375,0,.645,.5],[.645,0,.93,.5],[0,.5,.375,1],[.375,.5,.645,1],[.645,.5,.93,1]], [[.93,.1,1,.7]], c='many-panels', note='6 titled heatmaps sharing y labels; colorbar shared')
b('2602.06283v3-000', [[0,0,.51,1],[.51,0,1,1]], c='other', note='Traditional LSH vs SOCKET columns')
s('2609.35444v1-005')
b('2609.24352v1-026', [[0,0,.2,.82],[.2,0,.4,.82],[.4,0,.6,.82],[.6,0,.8,.82],[.8,0,1,.82]], [[0,.82,1,1]], c='many-panels', note='5 titled plots; legend shared')
x('2508.15475v2-011', 'more than 12 panels (45 small plots)')
s('2609.01428v1-000', 'architecture flowchart')
# grid 021
x('2610.19502v1-001', 'dense framework diagram; lettered sections overlap/interleave with arrows; ambiguous split')
s('2608.18498v1-000', 'connected framework')
x('2602.06886v5-000', 'more than 12 panels (two groups of many layer plots)')
b('2609.35630v1-003', [[0,0,.48,1],[.48,0,1,1]])
s('2605.12823v2-010')
b('2610.05023v1-003', [[0,0,.21,1],[.21,0,.375,1],[.375,0,.55,1],[.55,0,.735,1],[.735,0,1,1]], c='touching-raster', note='5 titled touching saliency maps; colorbar with last')
# grid 022
s('2608.27470v1-000', 'connected two-stage pipeline')
b('2610.03020v1-001', [[0,0,.42,1],[.42,0,1,1]], c='other', note='sunburst + statistics panel; unlettered')
s('2610.20816v1-001', 'connected architecture'); s('2609.02902v1-001')
b('2608.18413v1-004', [[0,0,.335,.5],[.335,0,.67,.5],[.67,0,1,.5],[0,.5,.335,1],[.335,.5,.67,1],[.67,.5,1,1]], c='touching-raster', note='6 titled touching renders')
s('2610.22157v1-000', 'connected schematic')
# grid 023
b('2610.13224v1-002', [[0,0,.5,1],[.5,0,1,1]], c='touching-raster', note='Training data / Inference results halves')
s('2507.05387v6-003'); s('2608.05706v1-004', 'unlettered rollout grid')
b('2405.07780v3-000', [[0,0,.5,1],[.5,0,1,1]], c='other', note='Traditional vs Ours with arrow')
b('2610.09111v1-003', [[0,.07,.385,1],[.385,.07,.69,1],[.69,.07,1,1]], [[.15,0,.85,.07]], note='legend shared')
s('2608.16927v1-002')
# grid 024
s('2608.09153v1-003', 'flowchart')
b('2601.08064v3-008', [[0,0,.35,.84],[.35,0,.66,.84],[.66,0,1,.84]], [[0,.84,1,1]], note='3 titled plots; legend and x-labels shared')
b('2609.34678v1-001', [[0,0,1,.3],[0,.3,1,.6],[0,.6,1,.87]], [[0,.87,1,1]], note='three titled stacked strip plots; legend shared')
b('2608.27797v1-005', [[0,0,1,.33],[0,.33,1,.66],[0,.66,1,1]], c='touching-raster', note='lettered frame strips')
s('2608.20384v1-003', 'flow diagram'); s('2602.09009v3-003', 'diagram')
# grid 025
s('2609.32157v1-002', 'pipeline of numbered stages joined by arrows')
b('2608.16927v1-001', [[0,0,.52,.88],[.52,0,1,.88]], [[0,.88,1,1]], note='legend shared')
s('2409.18804v3-000'); s('2609.02060v1-003', 'heatmap table')
b('2509.24560v2-003', [[0,0,.5,1],[.5,0,1,1]])
b('2609.03690v1-004', [[0,0,.335,.3],[.335,0,1,.3],[0,.3,.66,.62],[.66,.3,1,.62],[0,.62,1,.88],[0,.88,1,1]], c='many-panels', note='titled question-card groups; ambiguous L1/L2/L3 grouping')
# grid 026
s('2609.15239v1-001')
b('2609.38506v1-007', [[0,0,1,.46],[0,.46,1,.88]], [[.3,.88,.85,1]], c='plot-grid', note='Ours/SemlaFlow titled heatmap tables; colorbar shared')
b('2608.14866v1-003', [[0,0,.4,.5],[.4,0,.7,.5],[.7,0,1,.5],[0,.5,.4,1],[.4,.5,.7,1]], c='many-panels', note='5 titled violin panels')
s('2604.05158v3-001', 'connected architecture')
b('2605.12823v2-012', [[0,0,.5,1],[.5,0,1,1]])
x('2609.05309v1-008', 'more than 12 panels (43 layer matrices)')
# grid 027
_c=[0,.25,.5,.75,1]
b('2608.16564v1-002', [[_c[j],r0,_c[j+1],r1] for (r0,r1) in ((.03,.52),(.52,1)) for j in range(4)], [[.3,0,.7,.03]], c='many-panels', note='8 titled small plots; legend shared')
s('2610.15933v1-002', 'unlettered sample grid')
b('2607.11510v2-007', [[0,.08,.5,.55],[.5,.08,1,.55],[0,.55,.5,1],[.5,.55,1,1]], [[0,0,1,.08]], note='legend on top')
s('2608.14992v1-000', 'infographic: numbered stages joined by arrows')
# need sheet 000
b('2609.26063v1-001', [[0,0,.49,1],[.49,0,1,1]], note='vector found one panel')
b('2608.03967v1-006', [[0,0,.18,1],[.18,0,.34,1],[.34,0,.6,1],[.6,0,.81,1],[.81,0,1,1]], c='many-panels', note='vector merged c-e')
b('2609.32528v1-000', [[0,0,.29,1],[.29,0,1,.48],[.29,.48,1,1]], c='framed-diagrams')
b('2609.09899v1-003', [[0,0,.29,1],[.29,0,.63,1],[.63,0,1,1]], note='heatmaps found as one')
b('2610.26840v1-000', [[0,0,1,.26],[0,.26,1,.56],[0,.565,.48,1],[.48,.565,1,1]], c='framed-diagrams', note='a,b diagrams; c,d plots')
b('2610.25128v1-001', [[0,0,.37,1],[.37,0,.6,1],[.6,0,1,1]], note='scatter, violins, curve')
# need sheet 001
b('2610.12464v1-000', [[0,0,.46,1],[.46,0,1,1]], c='other', note='Left plot + Right image grid')
b('2610.09070v1-000', [[0,0,.42,.4],[.42,0,.7,.4],[.7,0,1,.4],[0,.4,.42,.84],[.42,.4,.7,.84],[.7,.4,1,.84]], [[0,.84,1,1]], c='many-panels', note='6 titled heatmaps; colorbar shared; first column carries row labels')
for k in NEED: assert k in A, k
# GT review fixes
g('2606.02363v2-005', [[1],[0,2]], note='(b) title found as separate vector panel')
b('2410.01917v3-000', [[0,0,.335,1],[.335,0,.645,1],[.645,0,1,1]], note='per-panel legends below; vgroup overlapped')
b('2608.16084v1-003', [[0,0,.455,.515],[.455,0,1,.515],[0,.515,.455,1],[.455,.515,1,1]], note='colorbar belongs to (b)')
b('2608.29903v1-009', [[0,0,.46,.462],[.46,0,.92,.462],[0,.462,.46,1],[.46,.462,.92,1]], [[.92,.2,1,.9]], note='heatmaps; shared colorbar and x-label')
b('2607.02486v2-002', [[0,0,.29,1],[.29,0,.56,1],[.56,0,.8,1]], [[.8,.1,1,.9]], note='legend shared (full height)')
x('2609.03690v1-004', 'ambiguous hierarchy of question cards (L1/L2/L3 groups interleave)')
b('2608.29903v1-009', [[0,0,.44,.462],[.44,0,.84,.462],[0,.462,.44,.96],[.44,.462,.84,.96]], [[.84,.1,1,.95],[.2,.96,.8,1]], note='heatmaps; shared colorbar and x-label')
