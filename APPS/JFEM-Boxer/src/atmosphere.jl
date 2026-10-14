# U.S. Standard Atmosphere 1976, lower-atmosphere equations (geometric -5..86 km).
# NOAA-S/T-76-1562 / NASA-TM-X-74335, Part 1, equations 18/19, 23, 33a/33b,
# ideal-gas density and speed of sound; molecular-weight correction Table 8.
# https://ntrs.nasa.gov/citations/19770009539
const ISA76_RADIUS_M = 6356766.0
const ISA76_G0 = 9.80665
const ISA76_R = 8314.32 / 28.9644
const ISA76_GAMMA = 1.4
const ISA76_HEIGHTS = (0.0, 11000.0, 20000.0, 32000.0, 47000.0, 51000.0, 71000.0)
const ISA76_LAPSES = (-0.0065, 0.0, 0.001, 0.0028, 0.0, -0.0028, -0.002)

geopotential_altitude(z::Real) = ISA76_RADIUS_M * z / (ISA76_RADIUS_M + z)
geometric_altitude(h::Real) = ISA76_RADIUS_M * h / (ISA76_RADIUS_M - h)

"""ISA76 at geometric altitude z (metres); no weather or ISA temperature offset."""
function isa1976(z::Real)
    isfinite(z) && -5000 <= z <= 86000 || throw(ArgumentError(
        "ISA 1976 altitude must be between -5000 and 86000 geometric metres"))
    h = geopotential_altitude(Float64(z))
    temperature, pressure, base = 288.15, 101325.0, 0.0
    for i in eachindex(ISA76_HEIGHTS)
        top = i == length(ISA76_HEIGHTS) ? h : min(h, ISA76_HEIGHTS[i+1])
        lapse = ISA76_LAPSES[i]
        next_temperature = temperature + lapse * (top - base)
        pressure *= lapse == 0 ? exp(-ISA76_G0 * (top-base)/(ISA76_R*temperature)) :
            (temperature/next_temperature)^(ISA76_G0/(ISA76_R*lapse))
        temperature = next_temperature
        h <= top && break
        base = top
    end
    # Molecular-scale temperature equals kinetic temperature below 80 km.
    # Above it the standard's M/M0 correction changes T and M together, so
    # density and sound speed continue to use the molecular-scale temperature.
    ratio = 1.0
    if z > 80000
        ratios = (1.0, .999996, .999989, .999971, .999941, .999909, .999870,
                  .999829, .999786, .999741, .999694, .999641, .999579)
        position = (z - 80000) / 500
        lower = min(floor(Int, position), 11)
        fraction = position - lower
        ratio = (1-fraction)*ratios[lower+1] + fraction*ratios[lower+2]
    end
    return Dict{String,Any}(
        "model" => "isa1976", "altitude_geometric_m" => Float64(z),
        "altitude_geopotential_m" => h, "pressure_altitude_ft" => h/0.3048,
        "temperature_K" => temperature*ratio, "pressure_Pa" => pressure,
        "density_kg_m3" => pressure/(ISA76_R*temperature),
        "speed_of_sound_m_s" => sqrt(ISA76_GAMMA*ISA76_R*temperature),
    )
end

"""Effective case atmosphere. Stored speed/altitude remain canonical SI values."""
function flight_condition(p::AbstractDict)
    mode = String(get(p, "aero.atmosphere", "manual"))
    mode in ("isa1976", "manual") || throw(ArgumentError("aero.atmosphere must be isa1976 or manual"))
    get(p,"aero.speed_unit","m/s") in ("m/s","knots","Mach") ||
        throw(ArgumentError("aero.speed_unit must be m/s, knots or Mach"))
    get(p,"aero.altitude_unit","m") in ("m","ft","FL") ||
        throw(ArgumentError("aero.altitude_unit must be m, ft or FL"))
    altitude = Float64(get(p,"aero.altitude",0.0))
    isfinite(altitude) && -5000 <= altitude <= 86000 || throw(ArgumentError(
        "aero.altitude must be between -5000 and 86000 geometric metres"))
    condition = mode == "isa1976" ? isa1976(altitude) : Dict{String,Any}(
        "model"=>"manual", "altitude_geometric_m"=>altitude,
        "altitude_geopotential_m"=>geopotential_altitude(altitude),
        "pressure_altitude_ft"=>nothing, "temperature_K"=>nothing, "pressure_Pa"=>nothing,
        "density_kg_m3"=>Float64(p["aero.density"]),
        "speed_of_sound_m_s"=>Float64(p["aero.speed_of_sound"]),
    )
    speed = Float64(p["aero.speed"])
    density, sound = condition["density_kg_m3"], condition["speed_of_sound_m_s"]
    all(x->isfinite(x)&&x>0, (speed,density,sound)) || throw(ArgumentError(
        "True airspeed, air density and speed of sound must be finite and greater than zero"))
    condition["speed_m_s"] = speed
    condition["Mach"] = speed/sound
    condition["q_Pa"] = 0.5*density*speed^2
    return condition
end
