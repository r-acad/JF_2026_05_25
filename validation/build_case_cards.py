#!/usr/bin/env python3
"""Build validation figures and two-page case cards from recorded solver data.

Optional documentation dependencies: numpy, matplotlib, reportlab, pypdf.
The Julia suite and the prebuilt PDFs do not require these Python packages.
Example: python validation/build_case_cards.py --output-dir build/case_cards
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import colors
from matplotlib.collections import LineCollection, PolyCollection
from matplotlib.ticker import MaxNLocator
from mpl_toolkits.mplot3d.art3d import Line3DCollection, Poly3DCollection
import numpy as np
from reportlab.lib import colors as rc
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, Image, PageBreak,
)

BLUE = "#155580"
INK = "#172c3b"
LIGHT = "#edf4f8"
ORANGE = "#a45a08"
plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 9, "axes.spines.top": False,
    "axes.spines.right": False, "axes.labelcolor": INK, "text.color": INK,
    "axes.titleweight": "semibold", "savefig.facecolor": "white",
    "svg.fonttype": "none", "pdf.fonttype": 42,
})


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def number(value, digits=5):
    if value is None:
        return "--"
    if isinstance(value, str):
        return value
    if not math.isfinite(float(value)):
        return str(value)
    return f"{value:.{digits}g}"


def clean(text):
    return str(text).replace("\u2011", "-").replace("\u2013", "-").replace("\u2014", "-")


def get_mesh(data):
    nodes = data.get("nodes", data.get("mesh", {}).get("nodes", []))
    if nodes and isinstance(nodes[0], dict):
        ids = [n["id"] for n in nodes]
        xyz = np.asarray([n.get("xyz", [n.get("x", 0), n.get("y", 0), n.get("z", 0)]) for n in nodes], dtype=float)
    else:
        ids = data["node_ids"]
        xyz = np.asarray(data["xyz"], dtype=float)
    index = {int(node_id): i for i, node_id in enumerate(ids)}
    records = data.get("elements", [])
    mesh = data.get("mesh", {})
    if not records:
        records = [dict(e, type=kind) for kind in ("quads", "trias", "bars", "rods") for e in mesh.get(kind, [])]
    faces, lines = [], []
    for e in records:
        conn = e.get("nodes", e.get("connectivity", [e.get("ga"), e.get("gb")]))
        try:
            conn = [index[int(n)] for n in conn]
        except (TypeError, KeyError):
            continue
        if len(conn) >= 3:
            faces.append(conn[:4] if len(conn) == 4 else conn[:3])
        elif len(conn) == 2:
            lines.append(conn)
    return xyz, faces, lines


def displacements(state, count):
    values = np.asarray(state.get("displacements", state.get("u", [])), dtype=float)
    if values.ndim == 1 and values.size == 6 * count:
        values = values.reshape(count, 6)
    if values.ndim != 2 or values.shape[0] != count or values.shape[1] < 3:
        raise ValueError(f"State {state.get('name')} must contain one displacement row per mesh node")
    if not np.isfinite(values[:, :3]).all():
        raise ValueError("Non-finite displacement data cannot be plotted")
    return values[:, :3]


def save_figure(fig, folder, name):
    folder.mkdir(parents=True, exist_ok=True)
    for suffix in ("png", "svg"):
        fig.savefig(folder / f"{name}.{suffix}", dpi=260, bbox_inches="tight", pad_inches=0.16)
    plt.close(fig)


def plane_axes(xyz, state):
    ranges = np.ptp(xyz, axis=0)
    extent = max(float(ranges.max()), 1e-12)
    active = np.flatnonzero(ranges > extent * 1e-7)
    u = displacements(state, len(xyz))
    if len(active) <= 1:
        along = int(np.argmax(ranges))
        transverse = np.max(np.abs(u), axis=0)
        transverse[along] = -1
        return along, int(np.argmax(transverse))
    if len(active) == 2:
        flat = int(next(i for i in range(3) if i not in active))
        if float(np.max(np.abs(u[:, flat]))) < max(float(np.linalg.norm(u, axis=1).max()) * 1e-6, 1e-14):
            return tuple(map(int, active))
    return None


def markers(ax, xyz, data, axes=None):
    ids = data.get("node_ids", [n["id"] for n in data.get("nodes", data.get("mesh", {}).get("nodes", []))])
    index = {int(g): i for i, g in enumerate(ids)}
    fixed = set(data.get("constrained_node_ids", []))
    for constraint in data.get("SPC1s", []):
        fixed.update(constraint.get("NODES", []))
    selected = [index[int(g)] for g in fixed if int(g) in index]
    if selected:
        selected = selected[::max(1, math.ceil(len(selected) / 100))]
        if axes is None:
            ax.scatter(*xyz[selected].T, c="#167c60", marker="^", s=15, depthshade=False, label="Constrained nodes")
        else:
            ax.scatter(xyz[selected, axes[0]], xyz[selected, axes[1]], c="#167c60", marker="^", s=22, zorder=5, label="Constrained nodes")
    loads = list(data.get("loads", []))
    loads += [{"node": f["GID"], "vector": np.asarray(f["Dir"]) * f["Mag"]} for f in data.get("FORCEs", []) if f.get("CID", 0) == 0]
    points, vectors = [], []
    for load in loads:
        if int(load.get("node", -1)) in index:
            points.append(xyz[index[int(load["node"])]] )
            vectors.append(np.asarray(load["vector"], dtype=float))
    if points:
        points, vectors = np.asarray(points), np.asarray(vectors)
        if len(points) > 12:
            points, vectors = points.mean(axis=0)[None, :], vectors.sum(axis=0)[None, :]
        extent = max(float(np.ptp(xyz, axis=0).max()), 1e-12)
        maximum = max(float(np.linalg.norm(vectors, axis=1).max()), 1e-300)
        arrows = vectors / maximum * extent * 0.10
        if axes is None:
            ax.quiver(*points.T, *arrows.T, color="#b3476a", linewidth=1.3, arrow_length_ratio=.25)
        else:
            ax.quiver(points[:, axes[0]], points[:, axes[1]], arrows[:, axes[0]], arrows[:, axes[1]],
                      angles="xy", scale_units="xy", scale=1, color="#b3476a", width=.005, label="Applied point force")


def draw_state(ax, xyz, faces, lines, state, title, length_unit="deck length unit", colorbar=True):
    u = displacements(state, len(xyz))
    is_mode = state.get("kind", "").lower() in ("mode", "modal", "buckling", "eigenvector")
    magnitude = np.linalg.norm(u, axis=1)
    extent = max(float(np.ptp(xyz, axis=0).max()), 1e-12)
    umax = float(magnitude.max())
    scale = 0.12 * extent / umax if umax else 1.0
    deformed = xyz + scale * u
    component = int(np.argmax(np.max(np.abs(u), axis=0)))
    field = u[:, component] if is_mode else magnitude
    if is_mode:
        denominator = max(float(np.max(np.abs(field))), 1e-300)
        field = field / denominator
        norm = colors.Normalize(-1, 1)
        cmap = plt.get_cmap("RdBu")
        label = f"Normalized U{'xyz'[component]} (arbitrary mode amplitude)"
    else:
        norm = colors.Normalize(0, max(float(field.max()), 1e-300))
        cmap = plt.get_cmap("viridis")
        label = f"Displacement magnitude [{length_unit}]"
    shown = faces
    axes = plane_axes(xyz, state)
    if axes is not None:
        ij = list(axes)
        if shown:
            ax.add_collection(LineCollection([xyz[f + [f[0]]][:, ij] for f in shown], colors="#87949d", linewidths=.55, alpha=.7))
            ax.add_collection(PolyCollection([deformed[f][:, ij] for f in shown], facecolors=[cmap(norm(float(field[f].mean()))) for f in shown], edgecolors=INK, linewidths=.55))
        if lines:
            ax.add_collection(LineCollection([xyz[e][:, ij] for e in lines], colors="#87949d", linewidths=1, linestyles="dashed"))
            ax.add_collection(LineCollection([deformed[e][:, ij] for e in lines], colors=[cmap(norm(float(field[e].mean()))) for e in lines], linewidths=3))
        ax.autoscale_view()
        ax.margins(.12)
        ax.set_aspect("equal", adjustable="datalim")
        ax.set_xlabel(f"{'XYZ'[axes[0]]} [{length_unit}]")
        ax.set_ylabel(f"{'XYZ'[axes[1]]} [{length_unit}]")
        ax.set_title(clean(title), fontsize=10, pad=12)
        ax.grid(alpha=.15)
        if colorbar:
            bar = ax.figure.colorbar(plt.cm.ScalarMappable(cmap=cmap, norm=norm), ax=ax, shrink=.80, pad=.03, aspect=22)
            bar.set_label(label, fontsize=8)
        return scale
    if shown:
        original = Line3DCollection([xyz[f + [f[0]]] for f in shown], colors="#7a8993", linewidths=0.35, alpha=0.35)
        ax.add_collection3d(original)
        face_colors = [cmap(norm(float(field[f].mean()))) for f in shown]
        deformed_faces = Poly3DCollection([deformed[f] for f in shown], facecolors=face_colors,
                                         edgecolors="none" if len(shown) > 5000 else "#283f4c",
                                         linewidths=0.22, alpha=1)
        ax.add_collection3d(deformed_faces)
    if lines:
        ax.add_collection3d(Line3DCollection([xyz[e] for e in lines], colors="#9da8af", linewidths=1.1, linestyles="dashed"))
        ax.add_collection3d(Line3DCollection([deformed[e] for e in lines],
                                            colors=[cmap(norm(float(field[e].mean()))) for e in lines], linewidths=2.8))
    if not shown and not lines:
        ax.scatter(*deformed.T, c=field, cmap=cmap, norm=norm, s=8)
    both = np.vstack([xyz, deformed])
    lower, upper = both.min(axis=0), both.max(axis=0)
    ranges = np.maximum(upper - lower, extent * 0.08)
    centers = (lower + upper) / 2
    for i, setter in enumerate((ax.set_xlim, ax.set_ylim, ax.set_zlim)):
        setter(centers[i] - ranges[i] * 0.57, centers[i] + ranges[i] * 0.57)
    ax.set_box_aspect(np.maximum(ranges, extent * 0.25))
    ax.view_init(elev=24, azim=-58)
    ax.set_xlabel("X", labelpad=1)
    ax.set_ylabel("Y", labelpad=1)
    ax.set_zlabel("Z", labelpad=1)
    ax.tick_params(labelsize=7, pad=0)
    for axis in (ax.xaxis, ax.yaxis, ax.zaxis):
        axis.pane.fill = False
        axis.set_major_locator(MaxNLocator(3))
    ax.grid(False)
    ax.set_title(clean(title), fontsize=10, pad=9)
    if colorbar:
        sm = plt.cm.ScalarMappable(cmap=cmap, norm=norm)
        bar = ax.figure.colorbar(sm, ax=ax, shrink=0.60, pad=0.16, aspect=22)
        bar.set_label(label, fontsize=8)
        bar.ax.tick_params(labelsize=7)
    return scale


def response_figure(meta, folder):
    rows = meta.get("convergence", [])
    metrics = [m for m in meta.get("metrics", []) if m.get("reference") is not None]
    fig, ax = plt.subplots(figsize=(7.6, 3.0))
    if meta.get("load_curve"):
        points = meta["load_curve"]
        end = max(p["tip_ux_m"] for p in points) * 1.04
        u = np.linspace(0, end, 180)
        stretch = 1 + u / meta["length_m"]
        ea = meta["E_Pa"] * meta["width_m"] * meta["thickness_m"]
        exact = ea * stretch * (stretch ** 2 - 1) / 2
        ax.plot(u * 1000, exact / 1000, color=BLUE, label="Independent finite-strain equation")
        ax.plot(u * 1000, ea * u / meta["length_m"] / 1000, color="#7b8790", linestyle="--", label="Small-strain tangent")
        ax.scatter([p["tip_ux_m"] * 1000 for p in points], [p["force_N"] / 1000 for p in points],
                   color="#b3476a", marker="o", s=28, zorder=4, label="JFEM: finest mesh, four load levels")
        ax.set_xlabel("Axial tip displacement [mm]")
        ax.set_ylabel("Applied reference-direction force [kN]")
        ax.set_title("Finite-stretch load-displacement verification")
        ax.legend(frameon=False, fontsize=8)
    elif meta.get("response_breakdown"):
        breakdown = meta["response_breakdown"]
        values = np.asarray(breakdown["values"]) * 1e6
        positions = np.arange(len(values))
        ax.bar(positions, values, width=.60, color=["#769fb9", "#b3476a", BLUE][:len(values)])
        ax.scatter([len(values) - 1], [breakdown["computed_total"] * 1e6], marker="D", color=ORANGE, zorder=4, label="JFEM total")
        for i, value in enumerate(values):
            ax.text(i, value + max(values) * .025, f"{number(value)}", ha="center", fontsize=9)
        ax.set_xticks(positions, breakdown["labels"])
        ax.set_ylim(0, max(values) * 1.20)
        ax.set_ylabel("Tip displacement [micrometres]")
        ax.set_title("Independent bending and shear contributions")
        ax.legend(frameon=False, fontsize=8)
    elif len(rows) > 1 and all(r.get("value") is not None for r in rows):
        groups = sorted(set(r.get("quantity", "Response") for r in rows))
        for group in groups:
            series = [r for r in rows if r.get("quantity", "Response") == group]
            x = [r.get("elements", r.get("resolution", i + 1)) for i, r in enumerate(series)]
            y = [abs(r["value"] / r["reference"] - 1) * 100 if r.get("reference") else r.get("error_percent", 0) for r in series]
            ax.plot(x, np.maximum(y, 1e-14), "o-", label=clean(group), markersize=4)
        ax.set_xscale("log")
        ax.set_yscale("log")
        ax.set_xlabel("Number of finite elements")
        ax.set_ylabel("Absolute relative error [%]")
        ax.set_title("Mesh study against the independent reference")
        ax.legend(frameon=False, fontsize=8)
    elif metrics:
        labels = [m.get("short_name", m["name"]).replace("_", " ") for m in metrics]
        ratios = [float(m["value"]) / float(m["reference"]) if float(m["reference"]) else 0 for m in metrics]
        positions = np.arange(len(metrics))
        ax.barh(positions, ratios, height=0.6, color=BLUE)
        ax.axvline(1, color=ORANGE, linestyle="--", label="Reference = 1")
        ax.set_yticks(positions, labels, fontsize=8)
        for i, m in enumerate(metrics):
            ax.text(ratios[i] + 0.015, i, f"{number(m.get('error_percent'))}%", va="center", fontsize=8)
        ax.set_xlim(0, max(1.15, max(ratios) * 1.22))
        ax.set_xlabel("JFEM / reference")
        ax.set_title("Recorded responses relative to the stated reference")
        ax.legend(frameon=False, loc="lower right", fontsize=8)
    else:
        ax.axis("off")
        ax.text(0.02, 0.85, "No independent numerical reference is available.", fontsize=12, weight="bold")
        ax.text(0.02, 0.60, "This case demonstrates workflow and model scale.\nRecorded values are reproducibility data, not an accuracy certificate.", fontsize=10)
    ax.grid(axis="x", alpha=0.18)
    fig.tight_layout()
    save_figure(fig, folder, "response")


def figures(meta, data, output):
    xyz, faces, lines = get_mesh(data)
    states = data.get("states", [])
    if not states:
        raise ValueError(f"{meta['id']}: no actual recorded state for figure generation")
    result_states = [s for s in states if s.get("kind") not in ("preload", "static_preload")]
    chosen = (result_states or states)[0]
    folder = output / "figures"
    fig = plt.figure(figsize=(7.6, 3.9))
    axes = plane_axes(xyz, chosen)
    ax = fig.add_subplot(111, **({"projection": "3d"} if axes is None else {}))
    def state_label(state):
        text = state.get("name", "Recorded JFEM result")
        kind = state.get("kind", "").lower()
        frequency = state.get("frequency")
        if frequency is None and kind in ("modal", "mode") and state.get("eigenvalue", 0) > 0:
            frequency = math.sqrt(state["eigenvalue"]) / (2 * math.pi)
        if frequency is not None and "hz" not in text.lower():
            text += f" | f = {number(frequency)} Hz"
        elif frequency is None and state.get("eigenvalue") is not None and "lambda" not in text.lower() and "load factor" not in text.lower():
            text += f" | load factor = {number(state['eigenvalue'])}"
        return text
    scale = draw_state(ax, xyz, faces, lines, chosen, state_label(chosen), meta.get("length_unit", "deck length unit"))
    markers(ax, xyz, data, axes)
    fig.subplots_adjust(left=.12 if axes is not None else 0, right=0.95, bottom=0.24 if axes is not None else 0.18, top=0.90)
    note = f"Shape amplified x{number(scale, 3)}; grey = original."
    if chosen.get("kind", "").lower() in ("mode", "modal", "buckling", "eigenvector"):
        note += " Eigenvector sign and amplitude are arbitrary."
    if len(faces) > 5000:
        note += " All faces shown; deformed edges hidden."
    fig.text(.02, .015, note, fontsize=7)
    save_figure(fig, folder, "deformation")
    modes = [s for s in states if s.get("kind", "").lower() in ("mode", "modal", "buckling", "eigenvector")][:4]
    if len(modes) > 1:
        rows = 1 if len(modes) <= 2 else 2
        fig = plt.figure(figsize=(7.6, 3.0 if rows == 1 else 5.8))
        for i, state in enumerate(modes):
            ax = fig.add_subplot(rows, 2, i + 1, **({"projection": "3d"} if plane_axes(xyz, state) is None else {}))
            label = state_label(state)
            draw_state(ax, xyz, faces, lines, state, label, meta.get("length_unit", "deck length unit"), colorbar=False)
        fig.subplots_adjust(left=.04, right=.98, bottom=.30 if rows == 1 else .15,
                            top=.94, wspace=.20, hspace=.85)
        fig.text(.02, .015, "Independently normalized eigenvectors; sign and amplitude arbitrary. Grey = original.", fontsize=7)
        save_figure(fig, folder, "modes")
    else:
        for suffix in ("png", "svg"):
            (folder / f"modes.{suffix}").unlink(missing_ok=True)
    response_figure(meta, folder)


def styles():
    font = "Helvetica"
    bold = "Helvetica-Bold"
    candidates = [Path("C:/Windows/Fonts/DejaVuSans.ttf"), Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")]
    for path in candidates:
        if path.exists():
            pdfmetrics.registerFont(TTFont("ValidationSans", str(path)))
            pdfmetrics.registerFont(TTFont("ValidationSansBold", str(path.with_name("DejaVuSans-Bold.ttf"))))
            font, bold = "ValidationSans", "ValidationSansBold"
            break
    result = getSampleStyleSheet()
    for name in ("Normal", "BodyText"):
        result[name].fontName = font
        result[name].fontSize = 8.3
        result[name].leading = 11.8
        result[name].textColor = rc.HexColor(INK)
        result[name].spaceAfter = 5
    result.add(ParagraphStyle(name="CardTitle", fontName=bold, fontSize=19, leading=23, textColor=rc.HexColor(BLUE), spaceAfter=8))
    result.add(ParagraphStyle(name="CardHead", fontName=bold, fontSize=10, leading=14, textColor=rc.HexColor(BLUE), spaceBefore=8, spaceAfter=5))
    result.add(ParagraphStyle(name="Small", fontName=font, fontSize=7, leading=9.4, textColor=rc.HexColor(INK), spaceAfter=4))
    result.add(ParagraphStyle(name="Tag", fontName=bold, fontSize=8.3, leading=12, textColor=rc.HexColor(ORANGE), spaceAfter=8))
    return result


def card(meta, output):
    st = styles()
    def p(text, style="BodyText"):
        return Paragraph(escape(clean(text)).replace("\n", "<br/>"), st[style])
    width = A4[0] - 32 * mm
    def image(name, height):
        from PIL import Image as PI
        path = output / "figures" / f"{name}.png"
        with PI.open(path) as im:
            ratio = im.height / im.width
        w = min(width, height / ratio)
        return Image(str(path), width=w, height=w * ratio)
    flow = [p("JFEM | REPRODUCIBLE VALIDATION CASE", "Small"), p(meta["title"], "CardTitle"),
            p(f"{meta['id']}  |  SOL {', '.join(map(str, meta.get('solutions', [])))}  |  {meta.get('evidence_class', 'Recorded benchmark')}", "Tag"),
            p(meta.get("description", ""))]
    definition = [("Geometry / mesh", meta.get("geometry", "See model.bdf")),
                  ("Material / section", meta.get("material", "See model.bdf")),
                  ("Boundary conditions", meta.get("boundary_conditions", "See model.bdf")),
                  ("Applied load", meta.get("loading", "See model.bdf"))]
    table = Table([[p(a, "Small"), p(b, "Small")] for a, b in definition], colWidths=[32 * mm, width - 32 * mm])
    table.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("BACKGROUND", (0, 0), (0, -1), rc.HexColor(LIGHT)), ("BOTTOMPADDING", (0, 0), (-1, -1), 5), ("TOPPADDING", (0, 0), (-1, -1), 5), ("LINEBELOW", (0, 0), (-1, -1), 0.3, rc.HexColor("#d6e1e8"))]))
    flow.extend([table, Spacer(1, 5 * mm), image("deformation", 88 * mm)])
    flow.append(p(meta.get("figure_caption", "Actual solver output. Deformation is amplified for visibility; mode vectors have arbitrary sign and amplitude."), "Small"))
    flow.append(p("Recorded numerical checks", "CardHead"))
    metrics = meta.get("metrics", [])
    rows = [[p(x, "Small") for x in ["Quantity [unit]", "JFEM", "Reference", "Error", "Assessment"]]]
    for m in metrics[:8]:
        rows.append([p(m["name"].replace("_", " ") + (f" [{m['unit']}]" if m.get("unit") else ""), "Small"), p(number(m.get("value")), "Small"), p(number(m.get("reference")), "Small"), p((number(m.get("error_percent")) + "%") if m.get("error_percent") is not None else "--", "Small"), p(m.get("status", "unmeasured"), "Small")])
    t = Table(rows, colWidths=[width * x for x in (.38, .15, .15, .14, .18)], repeatRows=1)
    t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("BACKGROUND", (0, 0), (-1, 0), rc.HexColor(LIGHT)), ("LINEBELOW", (0, 0), (-1, -1), 0.3, rc.HexColor("#d6e1e8")), ("TOPPADDING", (0, 0), (-1, -1), 5), ("BOTTOMPADDING", (0, 0), (-1, -1), 5)]))
    flow.append(t)
    flow.extend([PageBreak(), p("Evidence, convergence and interpretation", "CardTitle"), image("response", 72 * mm)])
    if (output / "figures/modes.png").exists():
        flow.extend([image("modes", 89 * mm), p("First available modes. Red/blue indicate opposite signed components; each mode is normalized independently.", "Small")])
    if meta.get("equations"):
        flow.append(p("Independent reference equations", "CardHead"))
        for equation in meta["equations"][:4]:
            flow.append(p(equation, "Small"))
    for sentence in meta.get("observations", [])[:3]:
        flow.append(p(sentence))
    for sentence in meta.get("limits", [])[:2]:
        flow.append(p("Scope: " + sentence, "Small"))
    flow.append(p("Reference and reproduction", "CardHead"))
    for source in meta.get("references", [])[:3]:
        flow.append(p(source.get("citation", source.get("title", "")) + " " + source.get("url", ""), "Small"))
    flow.append(p("Open the recorded .jfem file with Boxer: Project > Open JFEM results. For older eigenvalue files choose modal or buckling results when requested. The input deck and the recorded run receipt accompany the figures.", "Small"))
    flow.append(p(f"Run: {meta.get('run_date', '2026-10-19')} | Solver revision: {meta.get('solver_revision', 'see run receipt')} | Full precision values: results.json / metrics.csv", "Small"))
    def footer(canvas, doc):
        canvas.saveState()
        canvas.setStrokeColor(rc.HexColor("#c7d6e0"))
        canvas.line(16 * mm, 14 * mm, A4[0] - 16 * mm, 14 * mm)
        canvas.setFont("Helvetica", 7)
        canvas.setFillColor(rc.HexColor(INK))
        canvas.drawString(16 * mm, 10 * mm, f"JFEM - {meta['id']}")
        canvas.drawRightString(A4[0] - 16 * mm, 10 * mm, f"{doc.page}")
        canvas.restoreState()
    doc = SimpleDocTemplate(str(output / "case_card.pdf"), pagesize=A4, leftMargin=16 * mm, rightMargin=16 * mm,
                            topMargin=14 * mm, bottomMargin=20 * mm, title=meta["title"], author="JFEM validation suite")
    doc.build(flow, onFirstPage=footer, onLaterPages=footer)


def build(path, output_root):
    meta = read_json(path)
    folder = path.parent
    data = read_json(folder / meta.get("visual_file", "results/visual_data.json"))
    output = output_root / meta["id"]
    output.mkdir(parents=True, exist_ok=True)
    for metric in meta.get("metrics", []):
        value, reference, error = metric.get("value"), metric.get("reference"), metric.get("error_percent")
        if value is not None and reference not in (None, 0) and error is not None:
            expected = abs(value / reference - 1) * 100
            if not math.isclose(expected, error, rel_tol=1e-7, abs_tol=1e-8):
                raise ValueError(f"Inconsistent error for {meta['id']} / {metric['name']}")
    figures(meta, data, output)
    card(meta, output)
    with (output / "metrics.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=["name", "unit", "value", "reference", "error_percent", "tolerance_percent", "status"], extrasaction="ignore")
        writer.writeheader()
        writer.writerows(meta.get("metrics", []))
    from pypdf import PdfReader
    pages = len(PdfReader(output / "case_card.pdf").pages)
    if pages != 2:
        raise ValueError(f"{meta['id']}: expected a compact two-page card, got {pages}; revise layout/content")
    def digest(p):
        return hashlib.sha256(p.read_bytes()).hexdigest()
    receipt = {"schema": "jfem.validation.case_card.v1", "case_id": meta["id"],
               "built_utc": datetime.now(timezone.utc).isoformat(), "pdf_pages": pages,
               "case_metadata_sha256": digest(path), "visual_data_sha256": digest(folder / meta.get("visual_file", "results/visual_data.json")),
               "builder_sha256": digest(Path(__file__)), "source": "Recorded JFEM numerical fields; no synthetic deformation fields",
               "artifacts": {p.relative_to(output).as_posix(): digest(p) for p in output.rglob("*")
                             if p.is_file() and p.name != "case_card_receipt.json"}}
    (output / "case_card_receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return {"id": meta["id"], "pages": pages, "output": str(output), "figures": len(list((output / "figures").glob("*.png")))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases-root", type=Path, default=Path(__file__).parent / "cases")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--case", action="append", default=[])
    args = parser.parse_args()
    paths = sorted(args.cases_root.rglob("case.json"))
    # Some large published studies have a dedicated card layout and numerical
    # schema. Their adjacent builder documents how to reproduce those cards.
    paths = [p for p in paths if not (p.parent / "build_case_card.py").is_file()]
    if args.case:
        paths = [p for p in paths if read_json(p)["id"] in args.case]
    if not paths:
        parser.error("No selected case.json descriptors found")
    results = [build(p, args.output_dir) for p in paths]
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
