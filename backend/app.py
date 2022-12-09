from io import BytesIO
import os
import json
from flask import Flask, jsonify, request
import networkx as nx
import osmnx as ox
import geopandas as gpd
import momepy
from shapely import geometry
import numpy as np
from sklearn.cluster import KMeans
from flask_cors import CORS


def simplify(graph):
    vertices = [(n, d) for n, d in graph.nodes(data=True)]
    edges = [(n1, n2, d) for n1, n2, d in graph.edges(data=True)]
    return vertices, edges


def graph_to_json(graph):
    nodes, edges = momepy.nx_to_gdf(graph, points=True, lines=True)
    sedges = edges.loc[:, ['Type', 'geometry']].to_json()
    snodes = nodes.loc[nodes['Type'] != 'JUNC', [
        'Type', 'Name', 'ECC', 'PS', 'geometry']].to_json()

    return {'nodes': json.loads(snodes), 'edges': json.loads(sedges)}


def json_to_graph(jdata):
    node_bytes = json.dumps(jdata['nodes']).encode('utf-8')
    wnjson = BytesIO(node_bytes)
    points = gpd.read_file(wnjson).drop('id', axis=1)
    edge_bytes = json.dumps(jdata['edges']).encode('utf-8')
    wejson = BytesIO(edge_bytes)
    lines = gpd.read_file(wejson).drop('id', axis=1)
    return quick_graph(points, lines)


def quick_graph(points_df=None, lines_df=None):
    if points_df is None:
        points_df = gpd.read_file('database/points.shp')
    if lines_df is None:
        lines_df = gpd.read_file('database/lines.shp')

    graph = momepy.gdf_to_nx(lines_df, approach='primal')

    G = nx.Graph()

    G.add_edges_from([(n1, n2, d) for n1, n2, d in graph.edges(data=True)])

    vs = np.column_stack([points_df.loc[:, 'geometry'].x,
                         points_df.loc[:, 'geometry'].y])
    for n, d in G.nodes(data=True):
        ai = np.argwhere(vs == np.array(n))
        if len(ai) >= 1:
            i = ai[0][0]
            d['Type'] = points_df.loc[i, 'Type']
            d['Name'] = points_df.loc[i, 'Name']
            d['ECC'] = points_df.loc[i, 'ECC']
            d['PS'] = points_df.loc[i, 'PS']
            d['geometry'] = points_df.loc[i, 'geometry']
        else:
            d['Type'] = 'JUNC'
            d['Name'] = None
            d['ECC'] = None
            d['PS'] = None
            d['geometry'] = geometry.Point(*n)

    return G


def nodes_with_attribute(nodes, key, value, listed=False):
    if not listed:
        return [n for n, d in nodes if d[key] == value][0]
    else:
        return [n for n, d in nodes if d[key] == value]


def reduce(graph=None):
    if graph is None:
        graph = quick_graph()
    vertices, edges = simplify(graph)
    G = nx.Graph()
    ntypes = nx.get_node_attributes(graph, 'Type')
    edges = []

    untypes = {
        'Drop point': ['PLR', 'C4'],
        'PLR': ['SEC', 'C3'],
        'SEC': ['PRM', 'C2'],
        'PRM': ['Exchange', 'C1']
    }
    classification = {
        key: [n for n, d in vertices if d['Type'] == key] for key in untypes.keys()
    }

    edges = []
    for key, value in classification.items():
        masters = nodes_with_attribute(
            vertices, key='Type', value=untypes[key][0], listed=True)
        for sn in value:
            for mn in masters:
                spath = nx.shortest_path(graph, source=mn, target=sn)
                if len([n for n in spath if ntypes[n] != 'JUNC']) == 2:
                    edges.append((mn, sn,
                                  {'Type': untypes[key][1], 'geometry': geometry.LineString((mn, sn))}))
                    break

    G.add_nodes_from(vertices)
    G.add_edges_from(edges)
    return G


def optimal_centrality(max_attachments=None, relocate='PLR', ngraph=None):

    gmap = {
        'PLR': ['Drop point', 'SEC', 'C4', 'C3', 60],
        'SEC': ['PLR', 'PRM', 'C3', 'C2', 4],
        'PRM': ['SEC', 'Exchange', 'C2', 'C1', 2],
    }

    if ngraph is None:
        ngraph = reduce()

    nodes = [n[0] for n in ngraph.nodes(
        data=True) if n[1]['Type'] == gmap[relocate][0]]
    locs = np.array(nodes)

    if max_attachments is None:
        max_attachments = gmap[relocate][4]

    if len(nodes) < max_attachments:
        max_attachments = max(int(len(nodes)/8), 1)
    k = int(len(nodes)/max_attachments)

    kmeans = KMeans(
        init="random",
        n_clusters=k,
        n_init=10,
        max_iter=300,
        random_state=42
    )

    kmeans.fit(locs)

    ngraph.remove_nodes_from(
        [n[0] for n in ngraph.nodes(data=True) if n[1]['Type'] == relocate])

    for i in range(kmeans.n_clusters):
        center = kmeans.cluster_centers_[i]
        cnode = (center[0], center[1])
        ngraph.add_node(cnode, Type=f'{relocate}', Name=f'{relocate}{i}', geometry=geometry.Point(
            center[0], center[1]))
        for j in np.where(kmeans.labels_ == i)[0]:
            coords = locs[j]
            for node in nodes:
                if coords[0] in node and coords[1] in node:
                    ngraph.add_edge(cnode, node, Type=gmap[relocate][2], geometry=geometry.LineString(
                        [[node[0], node[1]], [cnode[0], cnode[1]]]))

    parents = [n[0] for n in ngraph.nodes(
        data=True) if n[1]['Type'] == gmap[relocate][1]]

    def dist(o, d):
        return np.sqrt((o[0]-d[0])**2 + (o[1]-d[1])**2)

    def min_dist_parent(n):
        min_dist = 100000
        parent = None
        for p in parents:
            if dist(n, p) < min_dist:
                min_dist = dist(n, p)
                parent = p
        return parent

    centralities = [n[0] for n in ngraph.nodes(
        data=True) if n[1]['Type'] == f'{relocate}']
    for centrality in centralities:
        parent = min_dist_parent(centrality)
        if parent is not None:
            ngraph.add_edge(centrality, parent, Type=gmap[relocate][3], geometry=geometry.LineString(
                [[parent[0], parent[1]], [centrality[0], centrality[1]]]))

    return ngraph


def get_bounds(vertices, edges):
    vb = gpd.GeoSeries([n[1]['geometry'] for n in vertices]).total_bounds
    eb = gpd.GeoSeries([n[2]['geometry'] for n in edges]).total_bounds
    mns = np.array([vb, eb]).min(axis=0)
    mxs = np.array([vb, eb]).max(axis=0)
    bounds = np.concatenate([mns[:2], mxs[2:]]).tolist()
    return bounds


def get_osm(vertices, edges):
    bounds = get_bounds(vertices, edges)
    minx, miny, maxx, maxy = bounds
    osm_graph = ox.graph.graph_from_bbox(
        north=maxy, south=miny, east=maxx, west=minx, network_type='walk')
    ox.io.save_graphml(osm_graph, filepath='database/osm.graphml',
                       gephi=False, encoding='utf-8')
    return osm_graph


def osm(vertices, edges):
    if os.path.isfile('database/osm.graphml'):
        osm_graph = ox.load_graphml('database/osm.graphml')
    else:
        osm_graph = get_osm(vertices, edges)
    return osm_graph


def _shortest_path(graph, destination_name, origin_name='E0', is_osm_graph=False):
    if not is_osm_graph:
        source = [n[0] for n in graph.nodes(
            data=True) if n[1]['Name'] == origin_name][0]
        target = [n[0] for n in graph.nodes(
            data=True) if n[1]['Name'] == destination_name][0]
    else:
        source = origin_name
        target = destination_name

    path_nodes_names = nx.shortest_path(graph, source, target)

    if not is_osm_graph:
        path_nodes = [(n, graph.nodes[n]) for n in path_nodes_names]
    else:
        path_nodes = path_nodes_names

    path_edges = graph.edges(path_nodes_names, data=True)
    filtered_path_edges = []
    for n1, n2, d in path_edges:
        if n1 in path_nodes_names and n2 in path_nodes_names:
            if not is_osm_graph:
                filtered_path_edges.append((n1, n2, d))
            else:
                filtered_path_edges.append((n1, n2))
    return path_nodes, filtered_path_edges


def shortest_path(graph, destination_names, origin_name='E0', is_osm_graph=False, return_graph=False):
    path_nodes = []
    filtered_path_edges = []
    for destination_name in destination_names:
        n, e = _shortest_path(graph, destination_name,
                              origin_name=origin_name, is_osm_graph=is_osm_graph)
        path_nodes.extend(n)
        filtered_path_edges.extend(e)

    if return_graph:
        shgraph = nx.Graph()
        shgraph.add_edges_from(filtered_path_edges)
        shgraph.add_nodes_from(path_nodes)
        return shgraph
    return path_nodes, filtered_path_edges


def unique(x):
    y = []
    for i in x:
        if i not in y:
            y.append(i)
    return y


def node_connections(graph, name, upto=None, return_graph=False):
    type_levels = {'Exchange': 0, 'PRM': 1,
                   'SEC': 2, 'PLR': 3, 'Drop point': 4}
    ntypes = nx.get_node_attributes(graph, 'Type')
    nnames = nx.get_node_attributes(graph, 'Name')
    onode = [n[0] for n in graph.nodes(data=True) if n[1]['Name'] == name][0]
    to_type = ntypes[onode]
    from_type = list(type_levels.keys())[min(type_levels[to_type]+1, 4)]

    spaths = []
    from_type_nodes = [n for n, d in graph.nodes(
        data=True) if d['Type'] == from_type]
    for ftnode in from_type_nodes:
        spath = nx.shortest_path(graph, onode, ftnode)
        is_true = True
        for snode in spath:
            if ntypes[snode] == 'JUNC' or nnames[snode] == name:
                continue
            if type_levels[ntypes[snode]] <= type_levels[to_type] or type_levels[ntypes[snode]] > type_levels[from_type]:
                is_true = False
                break
        if is_true:
            spaths.extend(spath)

    spaths = unique(spaths)
    path_nodes = [(n, graph.nodes[n]) for n in spaths]
    path_edges = graph.edges(spaths, data=True)
    path_edges = unique(path_edges)
    filtered_path_edges = []
    for n1, n2, d in path_edges:
        if n1 in spaths and n2 in spaths:
            filtered_path_edges.append((n1, n2, d))
    path_edges = filtered_path_edges

    if upto is not None:
        v, e = shortest_path(graph, destination_names=[
                             nnames[onode]], origin_name=upto)
        path_nodes.extend(v)
        path_edges.extend(e)
        path_nodes = unique(path_nodes)
        path_edges = unique(path_edges)

    if return_graph:
        ncgraph = nx.Graph()
        ncgraph.add_edges_from(path_edges)
        ncgraph.add_nodes_from(path_nodes)
        return ncgraph

    return path_nodes, path_edges


def circuits(graph, name, from_type, upto=None, return_graph=False):
    type_levels = {'Exchange': 0, 'PRM': 1,
                   'SEC': 2, 'PLR': 3, 'Drop point': 4}
    ntypes = nx.get_node_attributes(graph, 'Type')
    nnames = nx.get_node_attributes(graph, 'Name')
    onode = [n[0] for n in graph.nodes(data=True) if n[1]['Name'] == name][0]
    to_type = ntypes[onode]

    level_diff = type_levels[from_type]-type_levels[to_type]
    if level_diff > 1:
        ns = []
        es = []
        pnames = [name]
        _pnames = []
        for i in range(level_diff):
            for pname in pnames:
                n, e = node_connections(graph, pname)
                ns.extend(n)
                es.extend(e)
                gpnode = [gpn[0] for gpn in graph.nodes(
                    data=True) if gpn[1]['Name'] == pname][0]
                ptype = list(type_levels.keys())[
                    min(type_levels[ntypes[gpnode]]+1, 4)]
                _pnames.extend([nnames[pn]
                               for pn, pd in n if pd['Type'] == ptype])
            pnames.clear()
            pnames.extend(_pnames)

        if upto is not None:
            v, e = shortest_path(graph, destination_names=[
                                 nnames[onode]], origin_name=upto)
            ns.extend(v)
            es.extend(e)
            ns = unique(ns)
            es = unique(es)

        if return_graph:
            ncgraph = nx.Graph()
            ncgraph.add_edges_from(es)
            ncgraph.add_nodes_from(ns)
            return ncgraph
    else:
        return node_connections(graph, name, upto=upto, return_graph=return_graph)


def reverse_partial_reduction(rgraph, reverse_level_name, return_graph=False):
    rG = rgraph.copy()
    rGvertices, rGedges = simplify(rG)
    osm_graph = osm(rGvertices, rGedges)

    osmx = nx.get_node_attributes(osm_graph, 'x')
    osmy = nx.get_node_attributes(osm_graph, 'y')

    new_nodes = []
    new_edges = []
    to_be_removed_edges = []

    def nearest_node_id(point):
        nn = ox.nearest_nodes(osm_graph, point[0], point[1])
        return nn

    def route_ids(destinations, origin):
        osm_destination_ids = []
        for dnode, ddata in destinations:
            if ddata['Name'] == nnames[origin]:
                continue
            osm_destination_ids.append(nearest_node_id(dnode))

        osm_destination_ids = unique(osm_destination_ids)

        v, e = shortest_path(osm_graph, destination_names=osm_destination_ids,
                             origin_name=nearest_node_id(origin), is_osm_graph=True)

        return v, e

    origin = [n for n, d in rGvertices if d['Name'] == reverse_level_name][0]
    nnames = nx.get_node_attributes(rG, 'Name')
    ntypes = nx.get_node_attributes(rG, 'Type')
    type_levels = {'Exchange': 0, 'PRM': 1,
                   'SEC': 2, 'PLR': 3, 'Drop point': 4}
    edge_types = {'Exchange': 'C1', 'PRM': 'C2', 'SEC': 'C3', 'PLR': 'C4'}
    reverse_level_name_type = ntypes[origin]
    from_type_level = min(type_levels[reverse_level_name_type]+1, 4)
    from_type = list(type_levels.keys())[from_type_level]

    new_edge_type = edge_types[reverse_level_name_type]

    destinations, _ = node_connections(rG, name=reverse_level_name, upto=None)
    to_be_removed_edges.extend([(origin, dnode) for dnode, _ in destinations])
    to_be_removed_edges.extend([(dnode, origin) for dnode, _ in destinations])
    rG.remove_edges_from(to_be_removed_edges)

    v_ids = []
    e_ids = []

    v_id, e_id = route_ids(destinations, origin)

    v_ids.extend(v_id)
    e_ids.extend(e_id)
    v_ids = unique(v_ids)
    e_ids = unique(e_ids)

    new_nodes.extend([((osmx[v_id], osmy[v_id]), {
                     'Type': 'JUNC', 'Name': None, 'geometry': geometry.Point(osmx[v_id], osmy[v_id])}) for v_id in v_ids])
    new_edges.extend([
        (
            (osmx[e_id[0]], osmy[e_id[0]]),
            (osmx[e_id[1]], osmy[e_id[1]]),
            {
                'Type': new_edge_type,
                'geometry': geometry.LineString([[osmx[e_id[0]], osmy[e_id[0]]], [osmx[e_id[1]], osmy[e_id[1]]]])
            }
        ) for e_id in e_ids
    ])

    def nearest(node):
        n, d = node
        dist1 = [d['geometry'].distance(line['geometry'])
                 for _, _, line in new_edges]
        min_dist1 = np.min(dist1)
        dist2 = [d['geometry'].distance(point['geometry'])
                 for _, point in new_nodes]
        min_dist2 = np.min(dist2)

        if min_dist1 < min_dist2:
            feature = new_edges[np.argmin(dist1)]
            return feature, 0
        else:
            feature = new_nodes[np.argmin(dist2)]
            return feature, 1

    for n, d in destinations:
        near, near_type = nearest((n, d))
        if near_type == 1:
            near_node, near_d = near
            new_edges.append((
                n,
                near_node,
                {
                    'Type': new_edge_type,
                    'geometry': geometry.LineString([[n[0], n[1]], [near_node[0], near_node[1]]])
                }
            ))

        else:
            nn1, nn2, nd = near
            nn1x, nn1y = nn1
            nn2x, nn2y = nn2
            nnx, nny = n
            m = (nn2y - nn1y)/(nn2x-nn1x)
            py = (nnx*m + nny*m**2 - nn2x*m + nn2y)/(1+m**2)
            px = nnx - (py-nny)*m

            new_nodes.append(((px, py), {
                             'Type': 'JUNC', 'Name': None, 'geometry': geometry.Point(px, py)}))

            new_edges.append((
                nn1,
                (px, py),
                {
                    'Type': new_edge_type,
                    'geometry': geometry.LineString([[nn1[0], nn1[1]], [px, py]])
                }
            ))

            new_edges.append((
                nn2,
                (px, py),
                {
                    'Type': new_edge_type,
                    'geometry': geometry.LineString([[nn2[0], nn2[1]], [px, py]])
                }
            ))

            new_edges.append((
                n,
                (px, py),
                {
                    'Type': new_edge_type,
                    'geometry': geometry.LineString([[n[0], n[1]], [px, py]])
                }
            ))

            to_be_removed_edges.append((nn1, nn2))

    rG.add_nodes_from(new_nodes)
    rG.add_edges_from(new_edges)
    rG.remove_edges_from(to_be_removed_edges)

    if return_graph:
        for _ in range(6):
            to_be_removed_nodes = [n for n, d in rG.nodes(
                data=True) if d['Type'] == 'JUNC' and len(rG.edges(n)) < 2]
            rG.remove_nodes_from(to_be_removed_nodes)
        return rG

    return rG.nodes(data=True), rG.edges(data=True)


def hl_discrepancies(graph):
    nnames = nx.get_node_attributes(graph, 'Name')
    return {
        'Duplicates': [(nnames[n]) for n, d in graph.nodes(data=True) if d['Type'] == 'Drop point' and len(list(graph.edges(n))) > 1],
        'Disconnected': [(nnames[n]) for n, d in graph.nodes(data=True) if d['Type'] == 'Drop point' and len(list(graph.edges(n))) < 1]
    }


def e2e(graph, caller, reciever, return_graph=True):
    kkgraph = graph.copy()
    v, e = shortest_path(kkgraph, [reciever], origin_name=caller)

    for i, j, k in e:
        k['Type'] = 'Call'

    if return_graph:
        G = nx.Graph()
        G.add_nodes_from(v)
        G.add_edges_from(e)
        return G
    return v, e


def withinpoly(qgraph, gpoly):
    nnames = nx.get_node_attributes(qgraph, 'Name')
    gpoly = geometry.Polygon(gpoly)
    nodes = [(n, d) for n, d in qgraph.nodes(
        data=True) if d['geometry'].within(gpoly)]
    # edges = [(n1, n2, d) for n1, n2, d in qgraph.edges(data=True)
    #          if (n1, n2) in qgraph.edges([n for n, _ in nodes])]
    # edges = unique(edges)
    # G = nx.Graph()
    # G.add_nodes_from(nodes)
    # G.add_edges_from(edges)
    return [nnames[node] for node,d in nodes if d['Type']!='JUNC']


app = Flask(__name__)
CORS(app)


@app.after_request
def add_header(response):
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Headers'] = 'Access-Control-Allow-Origin, X-Requested-With, Content-Type, Accept'
    return response


@app.route("/")
@app.route("/home")
@app.route("/index")
def index():
    return "API Working"


@app.route("/api/graph/quick_graph", methods=['GET'])
def run_func1():
    G = quick_graph()
    return graph_to_json(G)


@app.route("/api/graph/reduce", methods=['POST'])
def run_func2():
    jdata = request.get_json()
    G = json_to_graph(jdata)
    rG = reduce(G)
    return graph_to_json(rG)


@app.route("/api/graph/op_cen/<string:relocate>/<int:max_attachments>", methods=['POST'])
def run_func3(relocate, max_attachments):
    if max_attachments==10000:
        max_attachments = None
    jdata = request.get_json()
    rG = json_to_graph(jdata)
    crG = optimal_centrality(
        max_attachments=max_attachments, relocate=relocate, ngraph=rG)
    return graph_to_json(crG)


@app.route("/api/graph/sh_pth/<string:origin>", methods=['POST'])
def run_func4(origin):
    # jdata = {gdata: {'nodes':{}, 'edges':{}}, 'destinations':[]}
    jdata = request.get_json()
    gdata = jdata['gdata']
    dest_names = jdata['destinations']
    G = json_to_graph(gdata)
    spG = shortest_path(G, dest_names, origin, return_graph=True)
    return graph_to_json(spG)


@app.route("/api/graph/allcircuits/<string:origin>", methods=['POST'])
def run_func5(origin):
    jdata = request.get_json()
    G = json_to_graph(jdata)
    acG = circuits(G, origin, 'Drop point', upto='E0', return_graph=True)
    return graph_to_json(acG)


@app.route("/api/graph/circuits/<string:origin>/<string:from_type>/<string:upto>", methods=['POST'])
def run_func6(origin, from_type, upto):
    jdata = request.get_json()
    G = json_to_graph(jdata)
    acG = circuits(G, origin, from_type, upto=upto, return_graph=True)
    return graph_to_json(acG)


@app.route("/api/graph/reverse_reduction/<string:origin>", methods=['POST'])
def run_func7(origin):
    jdata = request.get_json()
    rG = json_to_graph(jdata)
    rrG = reverse_partial_reduction(rG, origin, return_graph=True)
    return graph_to_json(rrG)


@app.route("/api/graph/withinpoly", methods=['POST'])
def run_func8():
    # jdata = {gdata: {'nodes':{}, 'edges':{}}, 'gpoly':[[],[],[],[]]}
    jdata = request.get_json()
    gdata = jdata['gdata']
    gpoly = jdata['gpoly']

    G = json_to_graph(gdata)
    node_names = withinpoly(G, gpoly)
    return {'nnames':node_names}


@app.route("/api/graph/hl_discrepancies", methods=['POST'])
def run_func9():
    """ response format {
        'Dups': [nodes],
        'Disc': [nodes]
    }"""
    jdata = request.get_json()
    G = json_to_graph(jdata)
    return hl_discrepancies(G)


@app.route("/api/graph/e2e/<string:caller>/<string:reciever>", methods=['POST'])
def run_func10(caller, reciever):
    jdata = request.get_json()
    G = json_to_graph(jdata)
    eG = e2e(G, caller, reciever, return_graph=True)
    return graph_to_json(eG)


if __name__ == "__main__":
    app.run(debug=False)
