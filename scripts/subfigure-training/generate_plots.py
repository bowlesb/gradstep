#!/usr/bin/env python3
"""Generate training-only scientific plots with renderer-derived annotation bounds.

No source article, model API, external font download or synthetic evaluation score.
The real validation/test files are copied byte-for-byte from the frozen parent set.
Generated labels are programmatic ground truth, not independent human review.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import shutil

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
from PIL import Image


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def rectangle(bounds,width,height):
    x0,y0,x1,y1=bounds.extents
    if x0<-.5 or y0<-.5 or x1>width+.5 or y1>height+.5:
        raise ValueError('Generated annotation outside image')
    result=[max(0.,float(x0)),max(0.,height-float(y1)),min(float(width),float(x1)),min(float(height),height-float(y0))]
    if result[2]<=result[0] or result[3]<=result[1]:raise ValueError('Empty generated label')
    return result


def make_plot(path,index,seed,shared_layouts=False):
    rng=np.random.default_rng(seed+index)
    layouts=[(1,2),(2,1),(2,2),(2,3),(3,2),(3,3),(4,1),(1,1)]
    nr,nc=layouts[index%len(layouts)]
    fontsize=int(rng.integers(9,15));dpi=int(rng.choice([100,125,150]))
    with plt.rc_context({'font.family':str(rng.choice(['DejaVu Sans','DejaVu Serif'])),
                         'font.size':fontsize,'axes.titlesize':fontsize,'axes.labelsize':fontsize,
                         'xtick.labelsize':fontsize-1,'ytick.labelsize':fontsize-1,
                         'axes.linewidth':float(rng.uniform(.6,1.5)),'savefig.facecolor':'white'}):
        shared_colorbar=shared_layouts and index%5==0
        column_titles=shared_layouts and nc>1 and index%3!=0
        right_legend=index%3==0 or shared_colorbar
        # Reserve physical space, not a fixed fraction: tall/narrow figures otherwise
        # put shared legends over plots and bottom legends over axis text.
        fw=max(6.5,nc*3.8+.9+(1.8 if right_legend else .2))
        bottom_inches=1.6 if right_legend else 2.1
        fh=nr*2.9+.8+bottom_inches
        fig,axes=plt.subplots(nr,nc,figsize=(fw,fh),dpi=dpi,squeeze=False)
        fig.subplots_adjust(left=.9/fw,right=1-(1.8 if right_legend else .2)/fw,
                            bottom=bottom_inches/fh,top=1-.8/fh,wspace=.38,hspace=.8)
        contexts=[];panel_kinds=[]
        handles=None;series_count=int(rng.integers(2,4))
        for k,ax in enumerate(axes.flat):
            kind='heatmap' if shared_colorbar else str(rng.choice(['line','scatter','bar','heatmap','errorbar']))
            panel_kinds.append(kind)
            n=int(rng.integers(20,80));x=np.linspace(.1,10,n)
            if kind=='heatmap':
                matrix=rng.normal(0,1,(int(rng.integers(8,24)),int(rng.integers(8,24))))
                plotted=ax.imshow(matrix,cmap='viridis' if shared_colorbar else str(rng.choice(['viridis','coolwarm','magma'])),
                                  aspect='auto',vmin=-3,vmax=3)
                # A per-panel color bar belongs to this complete panel, retained below.
                if not shared_colorbar:
                    cbar=fig.colorbar(plotted,ax=ax,fraction=.055,pad=.03)
                    cbar.set_label(str(rng.choice(['Correlation','Intensity','Error'])))
                    ax._gradstep_colorbar=cbar
            else:
                colors=['#366db1','#c24940','#4b8c54']
                lines=[]
                for series in range(series_count):
                    label=['Reference','Method A','Method B'][series]
                    y=np.sin(x*(series+1)/3)+series*.5+rng.normal(0,.06,n)
                    if kind=='line':
                        line,=ax.plot(x,y,label=label,color=colors[series],linestyle=['-','--',':'][series])
                    elif kind=='scatter':
                        line=ax.scatter(x,y,s=float(rng.uniform(5,18)),label=label,color=colors[series],marker=['o','x','+'][series])
                    elif kind=='bar':
                        line=ax.bar(np.arange(5)+series*.24,rng.uniform(.5,5,5),width=.23,label=label,color=colors[series])
                    else:
                        line=ax.errorbar(x[::5],y[::5],yerr=rng.uniform(.02,.25,len(x[::5])),label=label,color=colors[series],capsize=2)
                    lines.append(line)
                if handles is None:handles=lines
                if index%7==0:ax.legend(fontsize=max(7,fontsize-3),loc='best')
                if index%9==0 and kind in ('line','scatter'):ax.set_xscale('log')
            if index%2:
                ax.set_xlabel(str(rng.choice(['Training steps','Time [s]','Frequency [rad/s]','Sample size'])))
                ax.set_ylabel(str(rng.choice(['Magnitude [dB]','Accuracy [%]','Error','Signal'])))
            else:
                ax.set_xlabel('');ax.set_ylabel('')
            if rng.random()<.6:ax.grid(alpha=.25)
            # Labels deliberately vary above/below the chart, testing white-margin retention.
            label='('+chr(97+k)+')'
            if index%3==1 or column_titles:ax.annotate(label,(.5,0),xycoords='axes fraction',xytext=(0,-55),
                                     textcoords='offset points',ha='center',va='top',annotation_clip=False)
            else:ax.set_title(label+' '+str(rng.choice(['Experiment','Ablation','Response','Validation']))+f' {k+1}',pad=10)
        if column_titles:
            for c in range(nc):
                pos=axes[0,c].get_position()
                title=fig.text((pos.x0+pos.x1)/2,1-.35/fh,['Control','Treatment A','Treatment B'][c],ha='center',va='center')
                contexts.append((f'column-{c}',1,title,[r*nc+c for r in range(nr)],False))
        else:
            title=fig.suptitle(str(rng.choice(['Comparison across experimental conditions','Measured and estimated response',
                                              'Sensitivity to initialization','Results across independent trials'])),y=1-.1/fh)
            contexts.append(('title',1,title,list(range(nr*nc)),False))
        if shared_layouts and nr>1 and index%4==1:
            for r in range(nr):
                pos=axes[r,0].get_position()
                title=fig.text(.05/fw,(pos.y0+pos.y1)/2,f'Day {r+1}',rotation=90,ha='left',va='center')
                contexts.append((f'row-{r}',1,title,list(range(r*nc,(r+1)*nc)),False))
        if index%2==0:
            contexts.append(('shared-x',2,fig.supxlabel(str(rng.choice(['Time [s]','Training iteration','Frequency [Hz]'])),y=.05/fh),list(range(nr*nc)),False))
            contexts.append(('shared-y',3,fig.supylabel(str(rng.choice(['Normalized response','Error [%]','Measured intensity'])),x=.05/fw),list(range(nr*nc)),False))
        if shared_colorbar:
            color_axis=fig.add_axes([1-1.25/fw,bottom_inches/fh,.18/fw,1-(bottom_inches+.8)/fh])
            colorbar=fig.colorbar(plotted,cax=color_axis);colorbar.set_label('Normalized score')
            contexts.append(('shared-colorbar',0,color_axis,list(range(nr*nc)),False))
        if handles:
            inside=shared_layouts and index%6==2
            if inside:
                host=axes.flat[max(k for k in range(nr*nc) if panel_kinds[k]!='heatmap')]
                legend=fig.legend(handles,[h.get_label() for h in handles],loc='upper right',
                    bbox_to_anchor=(.98,.98),bbox_transform=host.transAxes,frameon=True,fontsize=max(8,fontsize-1))
            else:
                legend=fig.legend(handles,[h.get_label() for h in handles],
                    loc='center right' if right_legend else 'lower center',
                    bbox_to_anchor=(1-.08/fw,.52) if right_legend else (.5,.45/fh),
                    ncol=1 if right_legend else len(handles),frameon=index%2==0,fontsize=max(8,fontsize-1))
            contexts.append(('legend',0,legend,[k for k in range(nr*nc) if panel_kinds[k]!='heatmap'],inside))
        fig.canvas.draw();renderer=fig.canvas.get_renderer();width,height=fig.canvas.get_width_height()
        context_boxes=[{'id':name,'class':cls,'source_class':name,
                        'box':rectangle(artist.get_tightbbox(renderer) if name=='shared-colorbar' else artist.get_window_extent(renderer),width,height),
                        'origin':'matplotlib_renderer','applies_to_panels':applies,'intentional_overlap':overlap}
                       for name,cls,artist,applies,overlap in contexts]
        boxes=context_boxes[:]
        from matplotlib.transforms import Bbox
        for k,ax in enumerate(axes.flat):
            bounds=ax.get_tightbbox(renderer)
            if hasattr(ax,'_gradstep_colorbar'):bounds=Bbox.union([bounds,ax._gradstep_colorbar.ax.get_tightbbox(renderer)])
            boxes.append({'id':f'panel-{k}','class':4,'source_class':panel_kinds[k],
                          'box':rectangle(bounds,width,height),'origin':'matplotlib_renderer',
                          'required_context_ids':[b['id'] for b in context_boxes if k in b['applies_to_panels']]})
        for context in context_boxes:
            if context['intentional_overlap']:continue
            a=context['box'];context_area=(a[2]-a[0])*(a[3]-a[1])
            for panel in boxes[len(context_boxes):]:
                b=panel['box'];overlap=max(0,min(a[2],b[2])-max(a[0],b[0]))*max(0,min(a[3],b[3])-max(a[1],b[1]))
                if overlap/context_area>.01:raise ValueError(f'Generated context overlaps panel: {index} {context["id"]}')
        fig.savefig(path,dpi=dpi);plt.close(fig)
        if Image.open(path).size!=(width,height):raise ValueError('Renderer/save geometry changed')
        return width,height,boxes,panel_kinds


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,required=True);p.add_argument('--parent',type=Path,required=True)
    p.add_argument('--images',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--count',type=int,default=384);p.add_argument('--seed',type=int,default=71031)
    p.add_argument('--shared-layouts',action='store_true',help='Column/row headings, shared color bars and internal shared legends')
    args=p.parse_args()
    if args.out.exists() or args.images.exists():raise ValueError('Immutable generated revision already exists')
    parent=json.loads((args.parent/'manifest.json').read_text())
    for filename,digest in parent['files'].items():
        if sha(args.parent/filename)!=digest:raise ValueError('Parent split changed')
    args.out.mkdir(parents=True);args.images.mkdir(parents=True)
    rows=[json.loads(x) for x in (args.parent/'train.jsonl').read_text().splitlines()]
    generated=[];rejections=[]
    for i in range(args.count*3):
        identifier=f'generated-plot-{args.seed}-{i:04d}';path=args.images/(identifier+'.png')
        try:w,h,boxes,kinds=make_plot(path,i,args.seed,args.shared_layouts)
        except ValueError as e:
            plt.close('all');rejections.append({'id':identifier,'reason':str(e)})
            continue
        row={'id':identifier,'image':str(path.resolve().relative_to(args.root.resolve())),
            'sha256':sha(path),'width':w,'height':h,'paper':identifier,'group':'synthetic-training-only',
            'domain':'Generated','boxes':boxes,'source':'project matplotlib generator; no source paper',
            'review':'programmatic renderer bounds; not independent human review','split':'train',
            'generator_sha256':sha(__file__),'seed':args.seed+i,'plot_kinds':kinds}
        generated.append(row)
        if len(generated)%32==0:print(f'Admitted {len(generated)}/{args.count}; rejected {len(rejections)}',flush=True)
        if len(generated)==args.count:break
    if len(generated)!=args.count:raise ValueError('Insufficient valid generated figures within attempt bound')
    (args.out/'train.jsonl').write_text(''.join(json.dumps(r,sort_keys=True)+'\n' for r in rows+generated))
    for split in ('validation','test'):shutil.copyfile(args.parent/f'{split}.jsonl',args.out/f'{split}.jsonl')
    shutil.copyfile(args.parent/'attribution.json',args.out/'attribution.json')
    manifest=dict(parent);manifest.update(version=4,parent_manifest_sha256=sha(args.parent/'manifest.json'),
        generator={'script_sha256':sha(__file__),'matplotlib':matplotlib.__version__,'seed':args.seed,
                   'count':len(generated),'rejected':len(rejections),'shared_layouts':args.shared_layouts,
                   'training_only':True,'held_out_real_splits_unchanged':True},
        files={f'{s}.jsonl':sha(args.out/f'{s}.jsonl') for s in ('train','validation','test')})
    combined=rows+generated
    manifest['counts']['train'].update(images=len(combined),real_images=len(rows),generated_images=len(generated),
        real_boxes=parent['counts']['train']['boxes'],
        boxes=dict(collections.Counter(parent['classes'][b['class']] for r in combined for b in r['boxes'])),
        families=len({r['group'] for r in combined}),domains=dict(collections.Counter(r['domain'] for r in combined)),
        compound_images=sum(sum(b['class']==4 for b in r['boxes'])>1 for r in combined),
        explicit_panel_context_links=sum(len(b.get('required_context_ids',[])) for r in combined for b in r['boxes']),
        generated_boxes=dict(collections.Counter(parent['classes'][b['class']] for r in generated for b in r['boxes'])))
    (args.out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (args.out/'generated-rejections.json').write_text(json.dumps(rejections,indent=2)+'\n')
    (args.out/'generator-source.py').write_bytes(Path(__file__).read_bytes())
    print(json.dumps(manifest['generator']))


if __name__=='__main__':main()
