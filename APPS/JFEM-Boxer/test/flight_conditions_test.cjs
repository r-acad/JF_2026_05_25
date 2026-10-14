'use strict';
const assert=require('node:assert/strict'),F=require('../web/flight_conditions.js');
const close=(a,b,tol=1e-12)=>assert.ok(Math.abs(a-b)<=tol*Math.max(1,Math.abs(a),Math.abs(b)),`${a} != ${b}`);
const base={atmosphere:'isa1976',altitude:0,altitude_unit:'m',speed:100,speed_unit:'m/s',density:1.225,speed_of_sound:340,method:'vortex_lattice'};
close(F.isa1976(0).pressure_Pa,101325);
close(F.isa1976(F.geometric(11000)).temperature_K,216.65);
close(F.isa1976(F.geometric(11000)).pressure_Pa,22632.1,5e-6);
close(F.isa1976(86000).temperature_K,186.8673,1e-5);
for(const unit of ['m','ft','FL'])for(const altitude of [-1000,0,10000,86000])close(F.altitudeToSI(F.altitudeFromSI(altitude,unit),unit),altitude);
close(F.geopotential(F.altitudeToSI(300,'FL')),9144);
assert.notEqual(F.altitudeToSI(300,'FL'),30000*.3048);
for(const unit of ['m/s','knots','Mach'])close(F.speedToSI(F.speedFromSI(100,unit,310),unit,310),100);
close(F.speedToSI(1,'knots',340),1852/3600);
const mach={...base,speed_unit:'Mach',speed:F.isa1976(0).speed_of_sound_m_s*.4};
const high={...mach,...F.altitudeChange(mach,300,'FL')};
close(F.condition(high).Mach,.4);assert.ok(high.speed<mach.speed);
const tas={...base,...F.altitudeChange(base,300,'FL')};close(tas.speed,base.speed);
const manual={...high,...F.modeChange(high,'manual')};close(F.condition(manual).Mach,.4);close(manual.speed,high.speed);
const warmer={...manual,...F.atmosphereChange(manual,{speed_of_sound:330})};close(F.condition(warmer).Mach,.4);close(warmer.speed,132);
const json=JSON.parse(JSON.stringify(high));assert.deepEqual(F.condition(json),F.condition(high));
assert.throws(()=>F.isa1976(86001));assert.throws(()=>F.speedToSI('','Mach',340));assert.throws(()=>F.altitudeToSI(10,'yards'));
assert.equal(F.condition({...base,atmosphere:'manual'}).temperature_K,null);
if(process.argv[2]){
 const fixtures=JSON.parse(require('node:fs').readFileSync(process.argv[2],'utf8'));
 for(const[z,expected]of Object.entries(fixtures))for(const[key,value]of Object.entries(expected))if(typeof value==='number')close(F.isa1976(Number(z))[key],value,2e-14);
}
console.log('Flight-condition conversions, ISA values, Mach invariance and JSON round-trip passed.');
