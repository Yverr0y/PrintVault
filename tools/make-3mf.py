#!/usr/bin/env python3
"""Pack the sizing rings into one 3MF project, a ring to a plate.

Thirteen separate STLs means thirteen imports and thirteen arrangements before
anyone can print a range of sizes, which is most of the friction in actually
using the set. One project with a plate each removes all of it.

Plates are not part of the 3MF standard. They are a Bambu Studio extension that
OrcaSlicer reads too, recorded in Metadata/model_settings.config, and the plate
grid is not written down anywhere either: plate i sits at world
(col * 307, -row * 307) with four columns, the bed spanning 256 mm from there
and rows running towards -Y. Those numbers were read back out of a real
fourteen plate project rather than guessed at, and they reproduce all fourteen
of its placements.

Two things are load bearing and neither is obvious.

The Application metadata has to say BambuStudio. A file that names anything
else is treated as a foreign 3MF: the plate list is read, the names even
survive, and then every object is auto-arranged onto a grid of the slicer's
own and the assignments are thrown away. Thirteen plates came back as six
until this line said the right thing.

And there has to be a project_settings.config. It is what pins the bed size
the plate grid is derived from, and without one the slicer segfaults rather
than picking a default. 564 bytes of it is enough; the full 41 KB a real
project carries is that person's filament and print settings, which have no
business travelling with someone else's model.

The cost of both is that this is a Bambu Studio file. OrcaSlicer reads the
plate extension happily but rejects a Bambu printer profile, so it cannot
have one and there is no single file that satisfies both. The STLs remain
the answer for anything that is not Bambu Studio.

    python tools/make-3mf.py
"""

import os, struct, zipfile
from xml.sax.saxutils import quoteattr

BED, STRIDE, COLS = 256.0, 307.0, 4

def load_stl(path):
    b = open(path, 'rb').read()
    n = struct.unpack('<I', b[80:84])[0]
    out = []
    for i in range(n):
        o = 84 + 50 * i + 12
        out.append(tuple(struct.unpack('<3f', b[o + 12 * k:o + 12 * k + 12])
                         for k in range(3)))
    return out

def weld(tris):
    """A triangle soup into indexed geometry, which is what 3MF stores."""
    index, verts, faces = {}, [], []
    for t in tris:
        f = []
        for p in t:
            k = (round(p[0], 5), round(p[1], 5), round(p[2], 5))
            if k not in index:
                index[k] = len(verts)
                verts.append(k)
            f.append(index[k])
        if len(set(f)) == 3:                    # drop anything degenerate
            faces.append(f)
    return verts, faces

def plate_centre(i):
    """Where the middle of plate i lands in the single world the file uses."""
    col, row = i % COLS, i // COLS
    return col * STRIDE + BED / 2, -row * STRIDE + BED / 2

def model_xml(rings):
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<model unit="millimeter" xml:lang="en-US"'
           ' xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"'
           ' xmlns:BambuStudio="http://schemas.bambulab.com/package/2021">',
           # Load bearing, see the note at the top of this file.
           ' <metadata name="Application">BambuStudio-02.05.00.66</metadata>',
           ' <metadata name="BambuStudio:3mfVersion">1</metadata>',
           ' <metadata name="Title">Head sizing rings</metadata>',
           ' <metadata name="Designer">magikh0e</metadata>',
           ' <resources>']
    for n, (name, verts, faces, _) in enumerate(rings):
        mid, wid = 2 * n + 1, 2 * n + 2
        out.append('  <object id="%d" type="model">' % mid)
        out.append('   <mesh>')
        out.append('    <vertices>')
        out += ['     <vertex x="%.5f" y="%.5f" z="%.5f"/>' % v for v in verts]
        out.append('    </vertices>')
        out.append('    <triangles>')
        out += ['     <triangle v1="%d" v2="%d" v3="%d"/>' % tuple(f) for f in faces]
        out.append('    </triangles>')
        out.append('   </mesh>')
        out.append('  </object>')
        # Bambu wraps every mesh in a second object holding it as a component,
        # and the build item points at the wrapper rather than at the mesh.
        # Matching that, since it is what the slicer's own files do.
        out.append('  <object id="%d" type="model">' % wid)
        out.append('   <components>')
        out.append('    <component objectid="%d" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>'
                   % mid)
        out.append('   </components>')
        out.append('  </object>')
    out.append(' </resources>')
    out.append(' <build>')
    for n, (name, verts, faces, off) in enumerate(rings):
        out.append('  <item objectid="%d" transform="1 0 0 0 1 0 0 0 1 %.6f %.6f %.6f"'
                   ' printable="1"/>' % (2 * n + 2, off[0], off[1], off[2]))
    out.append(' </build>')
    out.append('</model>')
    return '\n'.join(out) + '\n'

def settings_xml(rings):
    out = ['<?xml version="1.0" encoding="UTF-8"?>', '<config>']
    for n, (name, verts, faces, _) in enumerate(rings):
        out.append('  <object id="%d">' % (2 * n + 2))
        out.append('    <metadata key="name" value=%s/>' % quoteattr(name))
        out.append('    <metadata key="extruder" value="1"/>')
        out.append('    <part id="%d" subtype="normal_part">' % (2 * n + 1))
        out.append('      <metadata key="name" value=%s/>' % quoteattr(name))
        out.append('      <metadata key="matrix" value="1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1"/>')
        out.append('      <mesh_stat face_count="%d" edges_fixed="0"'
                   ' degenerate_facets="0" facets_removed="0" facets_reversed="0"'
                   ' backwards_edges="0"/>' % len(faces))
        out.append('    </part>')
        out.append('  </object>')
    for n, (name, verts, faces, _) in enumerate(rings):
        out.append('  <plate>')
        out.append('    <metadata key="plater_id" value="%d"/>' % (n + 1))
        out.append('    <metadata key="plater_name" value=%s/>'
                   % quoteattr(name.split('-')[-1]))
        out.append('    <metadata key="locked" value="false"/>')
        out.append('    <metadata key="filament_map_mode" value="Auto For Flush"/>')
        out.append('    <model_instance>')
        out.append('      <metadata key="object_id" value="%d"/>' % (2 * n + 2))
        out.append('      <metadata key="instance_id" value="0"/>')
        # Without an identify_id the slicer does not match the instance back to
        # the object, drops the plate assignment and re-arranges the lot onto a
        # grid of its own. That was the whole difference between this file and
        # a known good one: six plates out of thirteen survived without it.
        out.append('      <metadata key="identify_id" value="%d"/>' % (100 + 2 * n))
        out.append('    </model_instance>')
        out.append('  </plate>')
    # Bambu writes an assemble entry per instance alongside the plates.
    out.append('  <assemble>')
    for n, _ in enumerate(rings):
        out.append('   <assemble_item object_id="%d" instance_id="0"'
                   ' transform="1 0 0 0 1 0 0 0 1 0 0 0" offset="0 0 0" />'
                   % (2 * n + 2))
    out.append('  </assemble>')
    out.append('</config>')
    return '\n'.join(out) + '\n'

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
 <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
 <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
 <Default Extension="png" ContentType="image/png"/>
</Types>
"""

RELS = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
</Relationships>
"""

# The smallest profile the slicer will accept: enough to know the bed, which
# is all the plate grid is derived from. Deliberately not a copy of anyone's
# real project settings.
PROJECT_SETTINGS = """{
    "printer_model": "Bambu Lab P2S",
    "printer_settings_id": "Bambu Lab P2S 0.4 nozzle",
    "printable_area": ["0x0", "256x0", "256x256", "0x256"],
    "printable_height": "256",
    "nozzle_diameter": ["0.4"],
    "print_settings_id": "0.20mm Standard @BBL P2S",
    "filament_settings_id": ["Generic PLA @BBL P2S"],
    "filament_type": ["PLA"],
    "from": "project",
    "version": "02.05.00.66",
    "name": "project_settings",
    "bed_exclude_area": [],
    "curr_bed_type": "Textured PEI Plate",
    "printer_technology": "FFF",
    "printer_variant": "0.4",
    "default_print_profile": "0.20mm Standard @BBL P2S"
}
"""

SLICE_INFO = """<?xml version="1.0" encoding="UTF-8"?>
<config>
  <header>
    <header_item key="X-BBL-Client-Type" value="slicer"/>
    <header_item key="X-BBL-Client-Version" value="01.09.00.00"/>
  </header>
</config>
"""

def main():
    src = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        '..', 'rings'))
    names = sorted((f for f in os.listdir(src) if f.endswith('.stl')),
                   key=lambda f: int(f.split('-')[2][:-6]))
    if not names:
        print('no rings found, run make-rings.py first')
        return

    rings = []
    for i, f in enumerate(names):
        verts, faces = weld(load_stl(os.path.join(src, f)))
        xs = [v[0] for v in verts]
        ys = [v[1] for v in verts]
        zs = [v[2] for v in verts]
        # Centre each mesh on its own origin and let the build item carry the
        # placement, which is how the slicer's own files are laid out.
        cx, cy, z0 = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, min(zs)
        verts = [(v[0] - cx, v[1] - cy, v[2] - z0) for v in verts]
        px, py = plate_centre(i)
        rings.append((f[:-4], verts, faces, (px, py, 0.0)))
        print('  plate %2d  %-22s %5d faces  %5d verts  centre (%6.1f, %6.1f)'
              % (i + 1, f[:-4], len(faces), len(verts), px, py))

    out = os.path.join(src, 'head-sizing-rings.3mf')
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        z.writestr('[Content_Types].xml', CONTENT_TYPES)
        z.writestr('_rels/.rels', RELS)
        z.writestr('3D/3dmodel.model', model_xml(rings))
        z.writestr('Metadata/model_settings.config', settings_xml(rings))
        z.writestr('Metadata/slice_info.config', SLICE_INFO)
        z.writestr('Metadata/project_settings.config', PROJECT_SETTINGS)
    print('\n  %s   %.0f KB' % (os.path.basename(out), os.path.getsize(out) / 1024))

if __name__ == '__main__':
    main()
