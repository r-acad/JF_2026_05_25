"""Author-generated analytical verification models. Python standard library only."""
from pathlib import Path
import json, math, argparse

CASES = {
 'ACA01':('cantilever_beam','Slender cantilever: static bending and natural frequencies'),
 'ACA02':('shear_flexible_beam','Short cantilever: Timoshenko shear flexibility'),
 'ACA03':('cross_ply_buckling','Symmetric cross-ply plate: Navier buckling'),
 'ACA04':('cross_ply_vibration','Symmetric cross-ply plate: Navier vibration'),
 'ACA05':('nonlinear_membrane','Finite-strain membrane: homogeneous uniaxial tension')}
REFS={
 'beam':{'title':'University of Alberta: Euler Bernoulli Beam','url':'https://engcourses-uofa.ca/books/introduction-to-solid-mechanics/plane-beam-approximations/euler-bernoulli-beam/','supports':'Beam assumptions and EI times fourth displacement derivative equals load; analytical cantilever response is independently derived.'},
 'shear':{'title':'University of Alberta: Timoshenko Beam','url':'https://engcourses-uofa.ca/books/introduction-to-solid-mechanics/plane-beam-approximations/timoshenko-beam/','supports':'Effective shear area and independent section rotation.'},
 'frequency':{'title':'Slater and Timbo: Engineering Vibration Toolbox, continuous systems','url':'https://vibrationtoolbox.github.io/vibration_toolbox/reference/continuous.html','supports':'Author-maintained academic continuous Euler beam eigenproblem.'},
 'plate':{'title':'Leissa, Vibration of Plates, NASA SP-160 (1969)','url':'https://ntrs.nasa.gov/citations/19700009156','supports':'Classical rectangular and anisotropic plate vibration theory.'},
 'buckling':{'title':'Weaver and Nemeth, Improved Design Formulae for Buckling of Orthotropic Plates under Combined Loading (2008)','url':'https://ntrs.nasa.gov/citations/20080015745','supports':'Orthotropic plate buckling framework; current finite rectangular Navier values are independently derived, not copied from fitted design formulae.'},
 'clt':{'title':'Nachiketa Tiwari / IIT Kanpur: Mechanics of Laminated Composite Structures, Lecture37 Buckling of Plates','url':'https://archive.nptel.ac.in/content/storage2/courses/112104161/L37.pdf','supports':'Finite symmetric specially orthotropic plate simply supported on all four sides, sinusoidal mode solution, uniaxial and biaxial buckling.'},
 'finite':{'title':'Idaho National Laboratory MOOSE: ComputeStVenantKirchhoffStress','url':'https://mooseframework.inl.gov/source/materials/lagrangian/ComputeStVenantKirchhoffStress.html','supports':'S=C:E using Green-Lagrange strain; P=F S. This is a theoretical benchmark, not an experimental material calibration.'}}

def write_json(p,d): p.write_text(json.dumps(d,indent=2)+'\n',encoding='utf-8')
def deck(p, lines): p.write_text('\n'.join(lines)+ '\n',encoding='ascii')
def base(sol,title): return [f'$ Author-generated academic verification: {title}',f'SOL {sol}','CEND',f'TITLE = {title}']

def beam(p,n,L,h,sol,shear=False):
 E=70e9; nu=.3; rho=2700.; b=.04; A=b*h; I=b*h**3/12; Iother=h*b**3/12; J=min(I,Iother); F=100. if shear else .1
 q=base(sol,'Shear-flexible cantilever' if shear else 'Slender cantilever')
 q+=['SUBCASE 1',' SPC=1']+([' METHOD=1'] if sol==103 else [' LOAD=1'])
 q+=['BEGIN BULK','PARAM,AUTOSPC,YES','PARAM,COUPMASS,1',f'MAT1,1,{E:.12g},,{nu},{rho}',f'PBAR,1,1,{A:.12g},{I:.12g},{Iother:.12g},{J:.12g},0.']
 if shear:q+=['+,,,,,,,,','+,0.833333333333333,0.833333333333333,0.']
 q += [f'GRID,{i+1},,{L*i/n:.12g},0.,0.' for i in range(n+1)]
 q += [f'CBAR,{i+1},1,{i+1},{i+2},0.,1.,0.' for i in range(n)]
 # Restrict to a single bending plane, avoiding mixed axial/torsional spectra.
 q += [f'SPC1,1,1345,{i+1}' for i in range(n+1)] + ['SPC1,1,26,1']
 q += ['EIGRL,1,,,4'] if sol==103 else [f'FORCE,1,{n+1},0,{F},0.,1.,0.']
 q+=['ENDDATA'];deck(p,q)
 return dict(E_Pa=E,nu=nu,rho_kg_m3=rho,width_m=b,height_m=h,length_m=L,area_m2=A,I_m4=I,load_N=F,shear_factor=5/6 if shear else None)

def plate(p,n,sol):
 a=.6;b=.4;t=.002;E1=135e9;E2=10e9;nu=.3;G=5e9;rho=1600.;Nx=1000.
 q=base(sol,'Simply supported cross-ply plate')
 if sol==105:q+=['SUBCASE 1',' SPC=1',' LOAD=1','SUBCASE 2',' SPC=1',' STATSUB=1',' METHOD=1']
 else:q+=['SUBCASE 1',' SPC=1',' METHOD=1']
 q+=['BEGIN BULK','PARAM,AUTOSPC,YES','PARAM,K6ROT,100.','PARAM,COUPMASS,1',f'MAT8,1,{E1:.12g},{E2:.12g},{nu},{G:.12g},{G:.12g},{G:.12g},{rho}',f'PCOMP,1,{-t/2:.12g},0.,,,,,',f'+,1,{t/4:.12g},0.,YES,1,{t/4:.12g},90.,YES',f'+,1,{t/4:.12g},90.,YES,1,{t/4:.12g},0.,YES']
 nid=lambda i,j:j*(n+1)+i+1
 q += [f'GRID,{nid(i,j)},,{a*i/n:.12g},{b*j/n:.12g},0.' for j in range(n+1) for i in range(n+1)]
 q += [f'CQUAD4,{j*n+i+1},1,{nid(i,j)},{nid(i+1,j)},{nid(i+1,j+1)},{nid(i,j+1)}' for j in range(n) for i in range(n)]
 for j in range(n+1):
  for i in range(n+1):
   g=nid(i,j);q.append(f'SPC1,1,6,{g}')
   if i in (0,n) or j in (0,n):q.append(f'SPC1,1,3,{g}')
   if i==0:q.append(f'SPC1,1,1,{g}')
 q+=['SPC1,1,2,1','EIGRL,1,,,6']
 if sol==105:
  q += [f'FORCE,1,{nid(n,j)},0,{Nx*b/n*(.5 if j in (0,n) else 1):.12g},-1.,0.,0.' for j in range(n+1)]
 q+=['ENDDATA'];deck(p,q)
 den=1-nu*nu*E2/E1;Q11=E1/den;Q22=E2/den;Q12=nu*E2/den;Q66=G
 D=[0.,0.,0.,0.]
 for k,theta in enumerate((0,90,90,0)):
  zm=-t/2+k*t/4;zp=zm+t/4;factor=(zp**3-zm**3)/3
  vals=(Q11,Q22,Q12,Q66) if theta==0 else (Q22,Q11,Q12,Q66)
  D=[d+v*factor for d,v in zip(D,vals)]
 modes=[]
 for m in range(1,15):
  for k in range(1,15):
   al=m*math.pi/a;be=k*math.pi/b;st=D[0]*al**4+2*(D[2]+2*D[3])*al**2*be**2+D[1]*be**4
   val=st/(Nx*al**2) if sol==105 else math.sqrt(st/(rho*t))/(2*math.pi)
   modes.append(dict(m=m,n=k,value=val))
 modes.sort(key=lambda x:x['value'])
 return dict(a_m=a,b_m=b,t_m=t,ply_angles_deg=[0,90,90,0],ply_t_m=t/4,E1_Pa=E1,E2_Pa=E2,nu12=nu,G12_Pa=G,rho_kg_m3=rho,Nx_N_m=Nx,D11_Nm=D[0],D22_Nm=D[1],D12_Nm=D[2],D66_Nm=D[3],analytical_modes=modes[:6])

def membrane(p,n,stretch):
 L=1.;b=.4;t=.01;E=70e6;nu=.3;P=.5*E*b*t*stretch*(stretch**2-1)
 q=base(106,'Homogeneous finite-strain membrane')+['SUBCASE 1',' SPC=1',' LOAD=1',' NLPARM=1','BEGIN BULK','PARAM,LGDISP,1','PARAM,NLMETHOD,AUTO','PARAM,AUTOSPC,YES','PARAM,K6ROT,100.',f'MAT1,1,{E:.12g},,{nu}',f'PSHELL,1,1,{t},1,,1','NLPARM,1,10,,,1,40,PW,NO','+,1.e-9,1.e-10,1.e-9']
 nid=lambda i,j:j*(n+1)+i+1
 q += [f'GRID,{nid(i,j)},,{L*i/n:.12g},{b*j/n:.12g},0.' for j in range(n+1) for i in range(n+1)]
 q += [f'CQUAD4,{j*n+i+1},1,{nid(i,j)},{nid(i+1,j)},{nid(i+1,j+1)},{nid(i,j+1)}' for j in range(n) for i in range(n)]
 for j in range(n+1):
  for i in range(n+1):
   g=nid(i,j);q.append(f'SPC1,1,3456,{g}')
   if i==0:q.append(f'SPC1,1,1,{g}')
 q+=['SPC1,1,2,1']
 q += [f'FORCE,1,{nid(n,j)},0,{P/n*(.5 if j in (0,n) else 1):.12g},1.,0.,0.' for j in range(n+1)]
 q+=['ENDDATA'];deck(p,q)
 return dict(length_m=L,width_m=b,t_m=t,E_Pa=E,nu=nu,stretch=stretch,total_force_N=P,exact_tip_ux_m=L*(stretch-1),exact_top_uy_m=b*(math.sqrt(1-nu*(stretch**2-1))-1))

def generate(root):
 root.mkdir(parents=True,exist_ok=True);specs=[]
 for cid,(slug,title) in CASES.items():
  folder=root/cid;folder.mkdir(exist_ok=True);runs=[]
  if cid=='ACA01':
   for sol in (101,103):
    for n in (4,8,16,32):
     name=f'cantilever_sol{sol}_n{n:02d}';props=beam(folder/(name+'.bdf'),n,2.,.01,sol)
     runs.append(dict(name=name,deck=name+'.bdf',sol=sol,n=n,parameters=props))
   eq=['w(x)=F*x^2*(3L-x)/(6EI)','theta(x)=F*x*(2L-x)/(2EI)','cos(beta)*cosh(beta)=-1','f_j=beta_j^2/(2*pi*L^2)*sqrt(EI/(rho*A))']
   refs=[REFS[x] for x in ('beam','frequency')];limits='One bending plane, Euler-Bernoulli idealization, linear isotropic elasticity; coupled translational mass without added rotary inertia. These are equation-verification cases rather than experiments.'
   tolerance=.5
  elif cid=='ACA02':
   for n in (1,2,4,8,16):
    name=f'timoshenko_n{n:02d}';props=beam(folder/(name+'.bdf'),n,1.,.2,101,True);runs.append(dict(name=name,deck=name+'.bdf',sol=101,n=n,parameters=props))
   eq=['G=E/(2*(1+nu))','A_s=kappa*A, kappa=5/6 explicitly specified','w_tip=F*L^3/(3*EI)+F*L/(kappa*G*A)','theta_tip=F*L^2/(2*EI)'];refs=[REFS['shear'],REFS['beam']];limits='Exact response of the one-dimensional Timoshenko model with user-selected effective shear area; not a three-dimensional elasticity reference.';tolerance=.01
  elif cid in ('ACA03','ACA04'):
   sol=105 if cid=='ACA03' else 103
   for n in (4,8,16,32,64):
    name=f'cross_ply_sol{sol}_n{n:02d}';props=plate(folder/(name+'.bdf'),n,sol);runs.append(dict(name=name,deck=name+'.bdf',sol=sol,n=n,parameters=props))
   eq=['D_ij=sum_k Qbar_ij(k)*(z_k^3-z_(k-1)^3)/3','alpha=m*pi/a; beta=n*pi/b','H=D11*alpha^4+2*(D12+2D66)*alpha^2*beta^2+D22*beta^4','lambda_mn=H/(Nx*alpha^2)' if sol==105 else 'f_mn=sqrt(H/(rho*t))/(2*pi)']
   refs=[REFS[x] for x in (('buckling','clt') if sol==105 else ('plate','clt'))];limits='Thin, flat, symmetric specially orthotropic laminate: B=D16=D26=0. Navier theory excludes transverse-shear deformation. The finite-element model adds transverse-shear flexibility and discretization effects. The modal case uses reference-surface mass without independent rotary inertia, matching that reference assumption. Edge-normal w constrained, bending rotations free. First six roots are compared in ascending order.';tolerance=2.
  else:
   for n in (1,2,4,8):
    for stretch in (1.005,1.02,1.05,1.10):
     name=f'membrane_n{n:02d}_stretch{stretch:.3f}'.replace('.','p');props=membrane(folder/(name+'.bdf'),n,stretch);runs.append(dict(name=name,deck=name+'.bdf',sol=106,n=n,parameters=props))
   eq=['F_2D=diag(lambda,mu); E_GL,2D=(F_2D^T*F_2D-I_2D)/2; thickness strain condensed by plane stress','S_yy=0 implies mu=sqrt(1-nu*(lambda^2-1))','P_xx=lambda*S_xx=E*lambda*(lambda^2-1)/2','F_total=P_xx*b*t; u_tip=(lambda-1)*L'];refs=[REFS['finite']];limits='Homogeneous in-plane finite-strain reduced plane-stress St Venant-Kirchhoff membrane verification. Thickness strain is condensed, not fixed to zero. All normal displacement and rotational DOFs constrained. This tests geometric nonlinear equations, not finite-rotation bending, plasticity, or measured material response.';tolerance=.01
  bcs={
   'ACA01':['x=0: uy=rz=0; every GRID: ux=uz=rx=ry=0 (one bending plane).','SOL101: global +Y tip force0.1N. SOL103: no applied load; coupled translational mass.'],
   'ACA02':['x=0: uy=rz=0; every GRID: ux=uz=rx=ry=0 (one bending plane).','Global +Y tip force100N. Effective shear area explicitly5/6 of gross area.'],
   'ACA03':['All four edges: uz=0; rotations rx,ry free. All GRID rz=0. x=0: ux=0. Origin: uy=0.','Uniform reference compression Nx=1000N/m on x=a via consistent nodal forces, one half weight at corners. Same SPC selected explicitly in preload and buckling subcases.'],
   'ACA04':['All four edges: uz=0; rotations rx,ry free. All GRID rz=0. x=0: ux=0. Origin: uy=0.','Free vibration with density1600kg/m3 in each ply; no applied load.'],
   'ACA05':['Every GRID: uz=rx=ry=rz=0. x=0: ux=0. Origin: uy=0. Other in-plane DOFs free.','Constant reference-direction traction on x=L; consistent nodal forces, half weight at corners. Ten continuation steps; independent loadlevels solve from zero.']}
  meta=dict(id=cid,slug=slug,title=title,reference_kind='independently_computed_analytical',references=refs,equations=eq,applicability=limits,boundary_conditions_and_loads=bcs[cid],units='SI: m, N, kg, s, Pa',acceptance=dict(relative_error_percent=tolerance,justification='Declared before execution. Beam/membrane values test exact element/model equations; thin laminate tolerance allows finite mesh convergence and thin-theory/model differences. All errors remain reported.'),runs=runs)
  write_json(folder/'case_definition.json',meta);specs.append(meta)
 write_json(root/'campaign.json',dict(cases=specs,model_authorship='New meshes/decks authored for JFEM analytical verification; no third-party input files or figures redistributed.'))
 return specs

if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('output',type=Path);args=parser.parse_args();generate(args.output)
