"""Regenerate this case's numerical figures and three-page card from recorded data.

Optional dependencies: numpy, matplotlib, reportlab, pypdf.
The output directory is separate from the published artifacts.
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse, hashlib, json, math
from xml.sax.saxutils import escape
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, Image, PageBreak
from pypdf import PdfReader

CASE=Path(__file__).resolve().parent
INK='#17364b'; BLUE='#17638e'; RED='#b34441'; LIGHT='#edf4f8'
plt.rcParams.update({'font.family':'DejaVu Sans','font.size':10,'axes.spines.top':False,
 'axes.spines.right':False,'axes.labelcolor':INK,'text.color':INK,'savefig.facecolor':'white','svg.fonttype':'none'})
def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def fmt(v):return '--' if v is None else f'{v:.7g}'

def figures(data,out):
    target=out/'figures';target.mkdir(parents=True,exist_ok=True)
    modes=data['modes'];n=len(modes)
    x=np.arange(1,n+1)
    fig,axes=plt.subplots(1,2,figsize=(10.4,3.4),layout='constrained')
    if n:
        reference=np.array([r['reference_frequency_Hz'] for r in modes]);actual=np.array([r['frequency_Hz'] for r in modes])
        axes[0].plot(x,reference,'o',ms=5,mfc='white',mec=INK,label='Published structural reference')
        axes[0].plot(x,actual,'x',ms=5,color=BLUE,label='JFEM')
        axes[1].plot(x,[r['frequency_error_percent'] for r in modes],'o-',lw=1,color=BLUE,label='Frequency error')
        axes[1].plot(x,[r['eigenvalue_error_percent'] for r in modes],'s--',lw=1,ms=4,color=RED,label='Angular eigenvalue error')
    axes[0].set(xlabel='Ascending mode number',ylabel='Natural frequency (Hz)')
    axes[1].axhspan(0,.5,color='#e3f1e8');axes[1].axhline(.5,color='#6a957b',lw=1,ls=':')
    axes[1].set(xlabel='Ascending mode number',ylabel='Absolute relative error (%)',ylim=(0,None))
    for ax in axes:
        ax.set_xlim(.5,20.5);ax.set_xticks([1,5,10,15,20]);ax.grid(alpha=.15);ax.legend(fontsize=8)
    fig.savefig(target/'modal_comparison.png',dpi=300);fig.savefig(target/'modal_comparison.svg');plt.close(fig)

    static=data['static'];nodes=sorted(static['tip_rib'],key=lambda p:p['xyz_m'][0]);ref=static['reference_displacement_m']
    fig,ax=plt.subplots(figsize=(9.5,3.5),layout='constrained')
    ax.plot([p['xyz_m'][0] for p in nodes],[p['translation_m'][2] for p in nodes],'o',ms=5,color=BLUE,label='All 21 original tip-rib GRIDs')
    p=next(p for p in nodes if p['node_id']==833)
    ax.plot(p['xyz_m'][0],p['translation_m'][2],'o',mfc='white',mec=RED,mew=2,ms=9,label='Predeclared inferred point: GRID 833')
    ax.annotate('GRID 833',(p['xyz_m'][0],p['translation_m'][2]),xytext=(12,-20),textcoords='offset points',color=RED)
    ax.axhline(ref,color=INK,ls='--',lw=1.3,label=f'Published tip scalar: {ref:g} m (point unspecified)')
    ax.set(xlabel='Tip-rib global X coordinate (m)',ylabel='Global vertical displacement Uz (m)')
    ax.grid(alpha=.18);ax.legend(loc='best',fontsize=8)
    fig.savefig(target/'static_tip_sampling.png',dpi=300);fig.savefig(target/'static_tip_sampling.svg');plt.close(fig)

def build(output):
    output.mkdir(parents=True,exist_ok=True)
    data=read(CASE/'results/comparison.json');meta=read(CASE/'case.json')
    figures(data,output)
    for font,bold in [('JFEMSans',False),('JFEMBold',True)]:
        pdfmetrics.registerFont(TTFont(font,font_manager.findfont(font_manager.FontProperties(family='DejaVu Sans',weight='bold' if bold else 'normal'))))
    styles=getSampleStyleSheet()
    styles.add(ParagraphStyle(name='BodyJF',fontName='JFEMSans',fontSize=9,leading=13,textColor=colors.HexColor(INK),spaceAfter=7))
    styles.add(ParagraphStyle(name='SmallJF',fontName='JFEMSans',fontSize=7.6,leading=10.5,textColor=colors.HexColor(INK),spaceAfter=6))
    styles.add(ParagraphStyle(name='TitleJF',fontName='JFEMBold',fontSize=23,leading=27,textColor=colors.HexColor(BLUE),spaceAfter=10))
    styles.add(ParagraphStyle(name='HeadJF',fontName='JFEMBold',fontSize=14,leading=18,textColor=colors.HexColor(BLUE),spaceAfter=8))
    def p(s,small=False):return Paragraph(s,styles['SmallJF' if small else 'BodyJF'])
    def h(s):return Paragraph(s,styles['HeadJF'])
    def table(rows,widths,small=True):
        rows=[[p(escape(str(v)),small) for v in row] for row in rows]
        t=Table(rows,colWidths=widths,repeatRows=1,hAlign='LEFT')
        t.setStyle(TableStyle([('VALIGN',(0,0),(-1,-1),'TOP'),('BACKGROUND',(0,0),(-1,0),colors.HexColor(LIGHT)),
          ('LINEBELOW',(0,0),(-1,-1),.3,colors.HexColor('#c9dbe7')),('LEFTPADDING',(0,0),(-1,-1),5),
          ('RIGHTPADDING',(0,0),(-1,-1),5),('TOPPADDING',(0,0),(-1,-1),4),('BOTTOMPADDING',(0,0),(-1,-1),2)]))
        return t
    def picture(path,width):
        from PIL import Image as PILImage
        w,ht=PILImage.open(path).size
        return Image(str(path),width=width,height=width*ht/w)
    flow=[p('JFEM | PUBLISHED COMPUTATIONAL STRUCTURAL BENCHMARK',True),Paragraph('uCRM9 original wingbox',styles['TitleJF']),
      p('Static cruise loading and the first 20 natural frequencies. The released anisotropic panel properties, engine mass cage, control-surface masses, fuel and constraints are retained.'),
      table([['Model definition','Original coarse structural model'],
        ['Mesh','23,738 wingbox GRIDs + 74 mass GRIDs; 25,055 CQUADR shells; 242 PSHELL regions and 968 MAT2 material cards.'],
        ['Sections','Smeared blade-stiffened aluminum panels. Separate membrane, bending, transverse-shear and membrane/bending coupling data are retained. Density 2780 kg/m3.'],
        ['Concentrated masses','Engine 7501 kg in a 13-point rigid cage; leading/trailing-edge masses 3669 kg; 20% fuel 11000.002 kg. 12 RBE2 and 62 RBE3 connections.'],
        ['Constraints','Root: 762 GRIDs constrained in 123456. Side of body: 627 distinct GRIDs in DOF 3, plus 11 in DOF 1. Original SPC set 1; 1389 unique constrained nodes.'],
        ['Load and modal controls','SOL101: fixed nominal-cruise aerodynamic FORCE set plus gravity -9.81 m/s2. SOL103: 20 modes. Original COUPMASS=-1, AUTOSPC=NO, K6ROT=1e5 and WTMASS=1.'],
        ['JFEM formulation','Native TACS-formulation shell backend with the common rigid-constraint, applied-load and concentrated-mass paths; full singular mass pencil retained.']],[35*mm,143*mm]),Spacer(1,5*mm),
      picture(CASE/'figures/boxer/21_published_uCRM9_shell_thickness.png',178*mm),
      p('Actual JFEM-Boxer screenshot of the original source model, white background. Color is the original PSHELL thickness in mm. Stiffener effects are smeared; these are not discrete beam sections.',True),
      p('Model and reference data: Brooks, Kenway and Martins, uCRM version 1 (2019), DOI 10.17632/gpk4zn73xn.1, CC BY 4.0. Associated article: AIAA Journal 56(7), 2840-2855 (2018), DOI 10.2514/1.J056603.',True),PageBreak(),
      h('Ordered natural frequency comparison')]
    modes=data['modes'];count=len(modes)
    if count:
        ef=max(r['frequency_error_percent'] for r in modes);el=max(r['eigenvalue_error_percent'] for r in modes)
        nf=sum(r['frequency_error_percent']<=.5 for r in modes);nl=sum(r['eigenvalue_error_percent']<=.5 for r in modes)
        flow.append(p(f'{count}/20 requested finite modes returned. Maximum error: {ef:.5g}% in frequency, {el:.5g}% in angular eigenvalue. Within 0.5%: {nf}/{count} frequencies and {nl}/{count} angular eigenvalues.'))
    else:flow.append(p('No qualified modal spectrum was returned. This is a solver coverage failure, not an accuracy pass.'))
    rows=[['Mode','Published Hz','JFEM Hz','Frequency error %','Eigenvalue error %']]
    for row in modes:rows.append([row['mode'],fmt(row['reference_frequency_Hz']),fmt(row['frequency_Hz']),fmt(row['frequency_error_percent']),fmt(row['eigenvalue_error_percent'])])
    flow.extend([table(rows,[13*mm,38*mm,37*mm,45*mm,45*mm]),Spacer(1,5*mm),picture(output/'figures/modal_comparison.png',178*mm),
      p('Error = 100|JFEM/reference - 1|. Angular eigenvalues are computed on both sides as (2 pi f)^2; frequency and eigenvalue errors are different measures. The shaded band is the 0.5% comparison criterion.',True),
      p('The workbook provides ordered scalar frequencies, not reference mode vectors. These are ascending-spectrum comparisons; modal identity has not been established by a MAC comparison. Original-pencil residuals and completeness diagnostics accompany the numerical results.',True),PageBreak(),
      h('Static tip response and observation point')])
    s=data['static'];tip=s['tip_rib'];vals=[r['translation_m'][2] for r in tip];at833=next(r['translation_m'][2] for r in tip if r['node_id']==833)
    flow.extend([p(f'The published coarse structural tip scalar is {s["reference_displacement_m"]:.7g} m. JFEM gives Uz = {at833:.9g} m at predeclared GRID 833. Across all 21 tip-rib nodes, Uz ranges from {min(vals):.9g} to {max(vals):.9g} m; the mean is {np.mean(vals):.9g} m.'),
      p('The authors do not identify a GRID or chord station for the tip scalar. GRID 833 is an inferred maximum-span observation, not an author-specified location. The range is reported without selecting the node that most closely matches the target; this static scalar is not assigned a qualified pass.'),
      picture(output/'figures/static_tip_sampling.png',178*mm),Spacer(1,3*mm),h('Scope and reproducibility'),
      p('These are independent published computational results, not experimental measurements. The separate coupled aeroelastic displacement of 2.591 m is not the target for this structural-only solve. The medium/fine workbook columns are author reference solutions, not JFEM mesh-convergence runs.'),
      p('The deck controls and physics are preserved. The reference solver release is unspecified. CQUADR uses the JFEM native TACS-formulation shell operator; retaining a card does not establish formulation identity. No artificial mass, diagonal stiffness or source-constraint removal is used to obtain modes.'),
      p('Anisotropic, independent-material and MID4 PSHELL force/stress recovery is not currently exported. Static translations and constraint reactions remain available in JSON; absent stresses are not represented as zero. Native modal results can be opened in Boxer.'),
      p('Reproduce from the shared repository environment:<br/><font face="Courier" size="7">julia --startup-file=no --project=. validation/cases/<br/>CRM_uCRM9_published/reproduce.jl</font>'),
      p('References and provenance: published_structural_references.csv retains all 63 coarse/medium/fine scalar targets and cell addresses; reference_provenance.json binds their workbook and archive-member hashes. curation_receipt.json records the sole software-name comment neutralization; every active card is identical to the source run.',True),
      p(f'Recorded run: {escape(meta["run_date"])}. Source revision: {escape(meta["solver_revision"])}. Full precision: results/comparison.json and metrics.csv. Source hashes: results/run_receipt.json. Stage timings: results/SOL101 and results/SOL103, in the adjacent TIMINGS.JSON files.',True)])
    def footer(canvas,doc):
        canvas.saveState();canvas.setFont('JFEMSans',7);canvas.setFillColor(colors.HexColor(INK));canvas.drawString(16*mm,10*mm,'JFEM | CRM_uCRM9_published');canvas.drawRightString(A4[0]-16*mm,10*mm,str(doc.page));canvas.restoreState()
    doc=SimpleDocTemplate(str(output/'case_card.pdf'),pagesize=A4,leftMargin=16*mm,rightMargin=16*mm,topMargin=14*mm,bottomMargin=18*mm,title='uCRM9 original wingbox validation',author='JFEM validation')
    doc.build(flow,onFirstPage=footer,onLaterPages=footer)
    pages=len(PdfReader(output/'case_card.pdf').pages)
    if pages!=3:raise ValueError(f'Expected3 compact pages; got{pages}. Revise layout.')
    receipt={'schema':'jfem.validation.case_card.v1','case_id':meta['id'],'built_utc':datetime.now(timezone.utc).isoformat(),
      'pdf_pages':pages,'builder':'build_case_card.py','builder_sha256':sha(Path(__file__)),
      'case_metadata_sha256':sha(CASE/'case.json'),'comparison_sha256':sha(CASE/'results/comparison.json'),
      'artifacts':{p.relative_to(output).as_posix():sha(p) for p in output.rglob('*') if p.is_file() and p.name!='case_card_receipt.json'}}
    (output/'case_card_receipt.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({'pdf_pages':pages,'output':str(output)}))

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output-dir',type=Path,required=True);args=parser.parse_args();build(args.output_dir)
