import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:soltel/graph.dart';
import 'package:soltel/routes_address.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SOLTEL',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key, required this.title}) : super(key: key);
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  bool isDrawerOpened = true;
  bool isGoogleMap = true;
  MapController mapController = MapController();
  LatLng centerLatLng = LatLng(24.688031, 46.688614);
  LatLng focusLatLng = LatLng(24.688031, 46.688614);
  double zoomLevel = 14.0;

  bool isQGloaded = false;

  late QGraph qGraph;
  Map graphSelectedPointInfo = {};

  List<Graph> loadedGraphsList = <Graph>[];
  List<NetworkPathGraph> networkPathGraphs = <NetworkPathGraph>[];

  bool isSlectionStarted = false;
  int selectionLimit = 0;
  String opperName = 'NA';
  List<String> selectedNodeNames = <String>[];
  List<Graph> actionGraphContainer = <Graph>[];

  bool isloading = false;
  bool isPolygonCreationStarted = false;
  bool isPolygonFilterEnabled = false;
  List<LatLng> polygonPoints = <LatLng>[];

  Map pointFilter = {
    'Exchange': true,
    'PRM': true,
    'SEC': true,
    'PLR': true,
    'Drop point': true,
    'ECC': {'0': true, '1': true, '2': true, '3': true},
    'PS': {'0': true, '1': true, '2': true, '3': true},
    'Nodes': []
  };
  int filterChangeID = 4015;

  void switchOnOffGraph(Graph graph, bool value) {
    graph.showPoints = value;
    graph.showLines = value;
    graph.isInFocus = value;
  }

  void startSelection(Graph graph, name, {int limit = 0}) {
    if (!isSlectionStarted) {
      isSlectionStarted = true;
      selectionLimit = limit;
      actionGraphContainer.add(graph);
      opperName = name;
    }
  }

  void stopSelection() {
    isSlectionStarted = false;
    actionGraphContainer.removeLast();
    selectionLimit = 0;
    selectedNodeNames = <String>[];
    opperName = 'NA';
  }

  Map changePointFocus(graph, newPointName) {
    Map infomap = graph.getInfoByName(newPointName);
    List coords = infomap['Coords'];
    if (coords != ['', '']) {
      focusLatLng = LatLng(coords[1], coords[0]);
    }
    return infomap;
  }

  changeSelectedPoint(Graph graph, String newPointName) {
    setState(() {
      graph.selectedPoint = newPointName;
      graph.removePreviousSelectionMarker();
      graph.addNewSelectionMarker();

      graphSelectedPointInfo = changePointFocus(graph, newPointName);

      if (isSlectionStarted &&
          (selectionLimit == 0 || selectedNodeNames.length < selectionLimit) &&
          !selectedNodeNames.contains(graphSelectedPointInfo['Name'])) {
        if (opperName == 'E2E') {
          if (graphSelectedPointInfo['Type'] == 'Drop point') {
            selectedNodeNames.add(graphSelectedPointInfo['Name']);
          }
        } else if (opperName == 'Reverse Direct') {
          if (graphSelectedPointInfo['Type'] == 'PLR') {
            selectedNodeNames.add(graphSelectedPointInfo['Name']);
          }
        } else {
          selectedNodeNames.add(graphSelectedPointInfo['Name']);
        }
      }
    });
  }

  void getQgraph() async {
    var res = await http.get(
      Uri.parse(basePoint + getQgraphURL),
    );
    qGraph.j2g(res);
    setState(() {
      graphSelectedPointInfo = qGraph.getInfoByName(qGraph.selectedPoint);
      isQGloaded = true;
      qGraph.isLoaded = true;
      loadedGraphsList.add(qGraph);
    });
  }

  Future<void> getRgraph() async {
    var res = await http.post(
      Uri.parse(basePoint + getRgraphURL),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: json.encode({'edges': qGraph.edges, 'nodes': qGraph.nodes}),
    );
    qGraph.rGraph = RGraph(changeSelectedPoint: changeSelectedPoint);
    qGraph.rGraph.j2g(res);
    setState(() {
      isloading = false;
      qGraph.isReduced = true;
      qGraph.rGraph.isLoaded = true;
      loadedGraphsList.add(qGraph.rGraph);
    });
  }

  Future<void> getNodesInPolygon(Graph graph) async {
    List<List<double>> gpoly = <List<double>>[];
    for (LatLng p in polygonPoints) {
      gpoly.add([p.longitude, p.latitude]);
    }
    gpoly.add([polygonPoints[0].longitude, polygonPoints[0].latitude]);

    var res = await http.post(
      Uri.parse(basePoint + getNodesInPolygonURL),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: json.encode({
        'gdata': {'edges': graph.edges, 'nodes': graph.nodes},
        'gpoly': gpoly
      }),
    );
    setState(() {
      var jres = json.decode(res.body) as Map;
      pointFilter['Nodes'] = jres['nnames'];
      filterChangeID += 1;
    });
  }

  Future<void> getGraphDiscrepancies(Graph graph) async {
    var res = await http.post(
      Uri.parse(basePoint + getGraphDiscrepanciesURL),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: json.encode({'edges': graph.edges, 'nodes': graph.nodes}),
    );

    var jres = json.decode(res.body) as Map;
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return discrepancyDialog(jres, graph);
      },
    );
  }

  Widget discrepancyDialog(Map dicrepancies, Graph graph) {
    List duplicates = dicrepancies['Duplicates'];
    List disconnected = dicrepancies['Disconnected'];
    return StatefulBuilder(builder: (stfContext, stfSetState) {
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        child: SizedBox(
          width: 200,
          height: 200,
          child: Column(
            children: [
              Expanded(
                child: glassMorphic(
                  SingleChildScrollView(
                    child: Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(0, 5, 0, 5),
                          child: Text(
                            'Duplicates',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              letterSpacing: 2,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        duplicates.isNotEmpty
                            ? Wrap(
                                spacing: 2,
                                alignment: WrapAlignment.center,
                                children: duplicates
                                    .map(
                                      (e) => GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            changeSelectedPoint(
                                                graph, e.toString());
                                            zoomLevel = 15;
                                            mapController.move(
                                                focusLatLng, zoomLevel);
                                          });
                                          Navigator.of(context).pop();
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.all(2),
                                          decoration: const BoxDecoration(
                                              color: Colors.blue,
                                              borderRadius: BorderRadius.all(
                                                  Radius.circular(20))),
                                          child: Padding(
                                            padding: const EdgeInsets.all(3.0),
                                            child: Text(
                                              e,
                                              style: const TextStyle(
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              )
                            : const Text(
                                'No duplicates found',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  letterSpacing: 1,
                                  fontWeight: FontWeight.normal,
                                ),
                              ),
                        const Padding(
                          padding: EdgeInsets.fromLTRB(0, 2, 0, 5),
                          child: Text(
                            'Disconnected',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              letterSpacing: 2,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        disconnected.isNotEmpty
                            ? Wrap(
                                spacing: 2,
                                alignment: WrapAlignment.center,
                                children: disconnected
                                    .map(
                                      (e) => Container(
                                        padding: const EdgeInsets.all(2),
                                        decoration: const BoxDecoration(
                                            color: Colors.blue,
                                            borderRadius: BorderRadius.all(
                                                Radius.circular(20))),
                                        child: Padding(
                                          padding: const EdgeInsets.all(3.0),
                                          child: Text(
                                            e,
                                            style: const TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              )
                            : const Text(
                                'No disconnections found',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  letterSpacing: 1,
                                  fontWeight: FontWeight.normal,
                                ),
                              ),
                      ],
                    ),
                  ),
                  alignment: Alignment.topCenter,
                ),
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: ElevatedButton(
                    child: const Text('Okay'),
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                  ),
                ),
              )
            ],
          ),
        ),
      );
    });
  }

  Future<Graph> _getCrGraph(
      Graph rgraph, String relocate, maxAttachments) async {
    var res = await http.post(
      Uri.parse(basePoint + getCgraphURL(relocate, maxAttachments)),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: json.encode({'edges': rgraph.edges, 'nodes': rgraph.nodes}),
    );
    CRGraph crGraph = CRGraph(changeSelectedPoint: changeSelectedPoint);
    crGraph.j2g(res);
    return crGraph;
  }

  Future<void> getCrGraph(Graph rgraph, String relocate, maxAttachments) async {
    Graph crGraph = await _getCrGraph(rgraph, relocate, maxAttachments);
    setState(() {
      isloading = false;
      crGraph.isLoaded = true;
      loadedGraphsList.add(crGraph);
    });
  }

  Future<void> getCircuit(Graph graph, String origin) async {
    var res = await http.post(
      Uri.parse(basePoint + getCircuitURL(origin)),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: json.encode({'edges': graph.edges, 'nodes': graph.nodes}),
    );
    Graph cirGraph = CircuitGraph(changeSelectedPoint: changeSelectedPoint);
    cirGraph.j2g(res);
    setState(() {
      isloading = false;
      cirGraph.isLoaded = true;
      loadedGraphsList.add(cirGraph);
    });
  }

  Future<void> getReversedRGraph(Graph graph, String origin) async {
    var res = await http.post(
      Uri.parse(basePoint + getReversedRGraphURL(origin)),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: json.encode({'edges': graph.edges, 'nodes': graph.nodes}),
    );
    Graph rrGraph =
        ReversedReducedGraph(changeSelectedPoint: changeSelectedPoint);
    rrGraph.j2g(res);
    setState(() {
      isloading = false;
      rrGraph.isLoaded = true;
      loadedGraphsList.add(rrGraph);
    });
  }

  Future<void> getNetworkPath(
      Graph graph, List<String> destinationNames) async {
    var res = await http.post(
      Uri.parse(basePoint + getNetworkPathURL('E0')),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: json.encode({
        'gdata': {'edges': graph.edges, 'nodes': graph.nodes},
        'destinations': destinationNames
      }),
    );

    NetworkPathGraph npg =
        NetworkPathGraph(changeSelectedPoint: changeSelectedPoint);
    npg.j2g(res);
    setState(() {
      isloading = false;
      npg.isLoaded = true;
      loadedGraphsList.add(npg);
    });
  }

  Future<void> getE2E(Graph graph, String caller, String reciever) async {
    var res = await http.post(
      Uri.parse(basePoint + getE2EURL(caller, reciever)),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: json.encode({'edges': graph.edges, 'nodes': graph.nodes}),
    );
    E2EGraph e2eg = E2EGraph(changeSelectedPoint: changeSelectedPoint);
    e2eg.j2g(res);
    setState(() {
      isloading = false;
      e2eg.isLoaded = true;
      loadedGraphsList.add(e2eg);
    });
  }

  void runOpperation(value, Graph graph) async {
    switch (value) {
      case 'Direct':
        if (!qGraph.isReduced && graph.graphType == 'UNDIRECTED') {
          setState(() {
            isloading = true;
            getRgraph();
          });
        }
        break;
      case 'Network Path':
        setState(() {
          startSelection(graph, value);
        });
        break;
      case 'E2E':
        setState(() {
          startSelection(graph, value, limit: 2);
        });
        break;
      case 'PLR Centrality':
        setState(() {
          isloading = true;
          getCrGraph(graph, 'PLR', 62);
        });
        break;
      case 'ALL Centrality':
        setState(() {
          isloading = true;
        });
        Graph g = graph;
        for (List relocate in [
          ['PLR', 10000],
          ['SEC', 10000],
          ['PRM', 10000]
        ]) {
          g = await _getCrGraph(g, relocate[0], relocate[1]);
        }
        setState(() {
          g.isLoaded = true;
          loadedGraphsList.add(g);
          isloading = false;
        });
        break;

      case 'Cicuits':
        setState(() {
          startSelection(graph, value, limit: 1);
        });
        break;
      case 'Reverse Direct':
        setState(() {
          startSelection(graph, value, limit: 1);
        });
        break;
      case 'Discrepancies':
        setState(() {
          getGraphDiscrepancies(graph);
        });
        break;
    }
  }

  Widget nodeSelections() {
    Graph graph = actionGraphContainer[0];
    return SizedBox(
      height: 100,
      child: Column(
        children: [
          const Text(
            'Select Nodes',
            style: TextStyle(
                color: Colors.lightBlueAccent,
                fontWeight: FontWeight.bold,
                fontSize: 14),
          ),
          Expanded(
            child: Wrap(
              spacing: 2,
              alignment: WrapAlignment.center,
              children: selectedNodeNames
                  .map(
                    (e) => Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                          color: Colors.blue,
                          borderRadius: BorderRadius.all(Radius.circular(20))),
                      child: Padding(
                        padding: const EdgeInsets.all(3.0),
                        child: Text(
                          e,
                          style: const TextStyle(
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          Row(
            children: [
              const Expanded(child: SizedBox()),
              TextButton(
                onPressed: () {
                  setState(() {
                    stopSelection();
                  });
                },
                child: const Text(
                  'Cancel',
                  style: TextStyle(
                      color: Colors.lightBlueAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 12),
                ),
              ),
              TextButton(
                onPressed: selectionLimit > 0 &&
                        selectedNodeNames.length < selectionLimit
                    ? null
                    : () async {
                        if (selectedNodeNames.isNotEmpty) {
                          switch (opperName) {
                            case 'Network Path':
                              setState(() {
                                isloading = true;
                                getNetworkPath(graph, selectedNodeNames);
                              });
                              break;
                            case 'E2E':
                              setState(() {
                                isloading = true;
                                getE2E(graph, selectedNodeNames[0],
                                    selectedNodeNames[1]);
                              });

                              break;
                            case 'Cicuits':
                              setState(() {
                                isloading = true;
                                getCircuit(graph, selectedNodeNames[0]);
                              });

                              break;
                            case 'Reverse Direct':
                              setState(() {
                                isloading = true;
                                getReversedRGraph(graph, selectedNodeNames[0]);
                              });
                              break;
                          }
                        }
                        setState(() {
                          stopSelection();
                        });
                      },
                child: const Text(
                  'Done',
                  style: TextStyle(
                      color: Colors.lightBlueAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String getTileURL() {
    return isGoogleMap
        ? 'https://mt1.google.com/vt/lyrs=r&x={x}&y={y}&z={z}'
        : 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png';
  }

  List getShps({point = false, line = false}) {
    if (isQGloaded) {
      for (Graph g in loadedGraphsList) {
        if (g.isInFocus) {
          return line
              ? g.qLines(filter: pointFilter, filterChangeID: filterChangeID)
              : g.qPoints(filter: pointFilter, filterChangeID: filterChangeID);
        }
      }
    }
    return [];
  }

  Widget glassMorphic(child,
      {width = double.infinity,
      height = double.infinity,
      shape = BoxShape.rectangle,
      alignment = Alignment.centerLeft}) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
        child: Container(
            alignment: alignment,
            width: width,
            height: height,
            decoration: BoxDecoration(
              shape: shape,
              gradient: LinearGradient(
                colors: [
                  Colors.deepPurple.withOpacity(0.9),
                  Colors.deepPurple.withOpacity(0.5),
                ],
                begin: AlignmentDirectional.topStart,
                end: AlignmentDirectional.bottomEnd,
              ),
              borderRadius: const BorderRadius.all(Radius.circular(10)),
              border: Border.all(
                width: 1.5,
                color: Colors.white.withOpacity(0.2),
              ),
            ),
            child: child),
      ),
    );
  }

  Widget zoomController() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Align(
        alignment: Alignment.bottomRight,
        child: glassMorphic(
            Column(children: [
              Expanded(
                child: Center(
                  child: IconButton(
                    onPressed: () {
                      setState(() {
                        zoomLevel = zoomLevel + 1.0;
                        mapController.move(focusLatLng, zoomLevel);
                      });
                    },
                    icon: const Icon(
                      Icons.zoom_in_map,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: IconButton(
                    onPressed: () {
                      setState(() {
                        zoomLevel = max(zoomLevel - 1.0, 5.0);
                        mapController.move(focusLatLng, zoomLevel);
                      });
                    },
                    icon: const Icon(
                      Icons.zoom_out_map,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ]),
            width: 50,
            height: 100),
      ),
    );
  }

  Align pushNpullDrawer() {
    return Align(
      alignment: isDrawerOpened ? Alignment.topRight : Alignment.topLeft,
      child: IconButton(
        icon: isDrawerOpened
            ? const Icon(
                Icons.arrow_back_ios,
                color: Colors.white70,
              )
            : const Icon(Icons.menu_open),
        onPressed: () {
          setState(() {
            isDrawerOpened = !isDrawerOpened;
          });
        },
      ),
    );
  }

  Row mapSwitcher() {
    return Row(
      children: [
        Expanded(
            child: Padding(
          padding: const EdgeInsets.only(left: 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              isGoogleMap ? 'GMAP' : 'OSM',
              style: const TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        )),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: Switch(
                value: isGoogleMap,
                onChanged: (value) {
                  setState(() {
                    isGoogleMap = value; //!isGoogleMap;
                  });
                }),
          ),
        ),
      ],
    );
  }

  Widget switchGraph(Graph graph) {
    return IconButton(
      icon: Icon(Icons.remove_red_eye,
          color: graph.isInFocus ? Colors.blueAccent : Colors.redAccent),
      onPressed: isSlectionStarted
          ? null
          : () {
              setState(() {
                for (Graph g in loadedGraphsList) {
                  if (g != graph) {
                    switchOnOffGraph(g, false);
                  }
                }
                switchOnOffGraph(graph, !graph.isInFocus);
                changePointFocus(graph, graph.selectedPoint);
              });
            },
    );
  }

  Container graphWidget(Graph graph) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 2),
      child: Column(
        children: [
          Row(children: [
            switchGraph(graph),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  graph.graphType,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: graph.isLoaded
                    ? DropdownButton(
                        icon: const Icon(Icons.arrow_drop_down_circle,
                            color: Colors.white70),
                        underline: const SizedBox(),
                        items: graph.functionKeys
                            .map(
                              (e) => DropdownMenuItem(
                                value: e,
                                child: SizedBox(
                                  width: 90,
                                  child: Text(
                                    e,
                                    style: const TextStyle(
                                        color: Colors.black87, fontSize: 12),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (isSlectionStarted || !graph.isInFocus)
                            ? null
                            : (value) {
                                runOpperation(value, graph);
                              },
                      )
                    : const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      ),
              ),
            )
          ]),
        ],
      ),
    );
  }

  Align pointDetails() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(children: [
          const Padding(
            padding: EdgeInsets.all(3.0),
            child: Text(
              'Details',
              style: TextStyle(
                fontSize: 14,
                color: Colors.white70,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ...graphSelectedPointInfo.entries.map(
            (e) => e.key != 'Coords'
                ? Row(children: [
                    Expanded(
                      child: Text(
                        e.key,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.bold,
                          fontSize: 10,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        e.value,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.normal,
                          fontSize: 10,
                        ),
                      ),
                    )
                  ])
                : const SizedBox(),
          ),
        ]),
      ),
    );
  }

  void startPolygonCreation() {
    isPolygonCreationStarted = true;
  }

  void stopPolygonCreation() {
    isPolygonCreationStarted = false;
  }

  Widget mapPointSelector() {
    return Container();
  }

  Widget filterDialog() {
    List<String> typeList = <String>[
      'Exchange',
      'PRM',
      'SEC',
      'PLR',
      'Drop point'
    ];
    Map eccMap = pointFilter['ECC'];
    Map psMap = pointFilter['PS'];

    // ignore: no_leading_underscores_for_local_identifiers
    Map _pointFilter = {'ECC': {}, 'PS': {}};
    pointFilter.forEach((key, value) {
      if (typeList.contains(key)) {
        _pointFilter[key] = value;
      }
    });
    eccMap.forEach((key, value) {
      _pointFilter['ECC'][key] = value;
    });
    psMap.forEach((key, value) {
      _pointFilter['PS'][key] = value;
    });

    return StatefulBuilder(builder: (stfContext, stfSetState) {
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        child: SizedBox(
          width: 300,
          height: 380,
          child: Center(
            child: Column(
              children: [
                Expanded(
                  child: glassMorphic(
                    SingleChildScrollView(
                      child: Column(
                        children: [
                          ...typeList.map(
                            (e) => Row(
                              children: [
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        20, 5, 5, 2.5),
                                    child: Text(
                                      e,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(5, 5, 15, 2.5),
                                  child: Switch(
                                    onChanged: (value) {
                                      stfSetState(() {
                                        _pointFilter[e] = value;
                                      });
                                    },
                                    value: _pointFilter[e],
                                  ),
                                )
                              ],
                            ),
                          ),
                          Row(
                            children: [
                              const Expanded(
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(20, 5, 5, 2.5),
                                  child: Text(
                                    'ECC',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(5, 5, 15, 2.5),
                                child: Row(
                                  children: eccMap.entries.map((entry) {
                                    return Row(
                                      children: [
                                        Text(
                                          '${entry.key}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(right: 5),
                                          child: Checkbox(
                                              value: _pointFilter['ECC']
                                                  [entry.key],
                                              onChanged: (value) {
                                                stfSetState(() {
                                                  _pointFilter['ECC']
                                                      [entry.key] = value;
                                                });
                                              }),
                                        )
                                      ],
                                    );
                                  }).toList(),
                                ),
                              )
                            ],
                          ),
                          Row(
                            children: [
                              const Expanded(
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(20, 5, 5, 5),
                                  child: Text(
                                    'PS',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(5, 5, 15, 2.5),
                                child: Row(
                                  children: psMap.entries.map((entry) {
                                    return Row(
                                      children: [
                                        Text(
                                          '${entry.key}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(right: 5),
                                          child: Checkbox(
                                              value: _pointFilter['PS']
                                                  [entry.key],
                                              onChanged: (value) {
                                                stfSetState(() {
                                                  _pointFilter['PS']
                                                      [entry.key] = value;
                                                });
                                              }),
                                        )
                                      ],
                                    );
                                  }).toList(),
                                ),
                              )
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 2.5, 0, 2.5),
                  child: Row(
                    children: [
                      const Expanded(child: SizedBox()),
                      ElevatedButton(
                        child: const Text('Apply'),
                        onPressed: () {
                          setState(() {
                            _pointFilter['Nodes'] = pointFilter['Nodes'];
                            pointFilter = _pointFilter;

                            filterChangeID += 1;
                          });
                          Navigator.of(context).pop();
                        },
                      ),
                      const SizedBox(
                        width: 10,
                        height: 1,
                      ),
                      GestureDetector(
                          onTap: () {
                            stfSetState(() {
                              if (isPolygonFilterEnabled) {
                                pointFilter['Nodes'] = [];
                                setState(() {
                                  filterChangeID += 1;
                                });
                                isPolygonFilterEnabled = false;
                              } else {
                                if (polygonPoints.isNotEmpty) {
                                  isPolygonFilterEnabled = true;
                                }
                              }
                            });
                            Navigator.of(context).pop();
                          },
                          onLongPress: () {
                            setState(() {
                              startPolygonCreation();
                            });
                            Navigator.of(context).pop();
                          },
                          child: Icon(
                            Icons.hexagon,
                            color: isPolygonFilterEnabled
                                ? Colors.blueAccent
                                : Colors.redAccent,
                          ))
                    ],
                  ),
                )
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget editMarkerDialog() {
    TextEditingController searchedNodeNameController = TextEditingController();
    return StatefulBuilder(builder: (stfContext, stfSetState) {
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        child: SizedBox(
          width: 200,
          height: 150,
          child: Column(
            children: [
              Expanded(
                child: glassMorphic(
                  SingleChildScrollView(
                    child: Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(5, 15, 5, 5),
                          child: Text(
                            'Enter name of the node',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(5, 5, 5, 15),
                          child: TextField(
                            textAlign: TextAlign.center,
                            controller: searchedNodeNameController,
                            style: const TextStyle(
                                fontSize: 14,
                                height: 2.0,
                                color: Colors.white,
                                letterSpacing: 2),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  alignment: Alignment.topCenter,
                ),
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: ElevatedButton(
                    child: const Text('Search'),
                    onPressed: () {
                      setState(() {
                        for (Graph g in loadedGraphsList) {
                          if (g.isInFocus) {
                            String sName = searchedNodeNameController.text;
                            Map infoMap = g.getInfoByName(sName);
                            if (infoMap['Type'] != '') {
                              changeSelectedPoint(g, sName);
                              zoomLevel = 15;
                              mapController.move(focusLatLng, zoomLevel);
                            }
                          }
                        }
                      });
                      Navigator.of(context).pop();
                    },
                  ),
                ),
              )
            ],
          ),
        ),
      );
    });
  }

  Widget searchDialog() {
    TextEditingController searchedNodeNameController = TextEditingController();
    return StatefulBuilder(builder: (stfContext, stfSetState) {
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        child: SizedBox(
          width: 200,
          height: 150,
          child: Column(
            children: [
              Expanded(
                child: glassMorphic(
                  SingleChildScrollView(
                    child: Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(5, 15, 5, 5),
                          child: Text(
                            'Enter name of the node',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(5, 5, 5, 15),
                          child: TextField(
                            textAlign: TextAlign.center,
                            controller: searchedNodeNameController,
                            style: const TextStyle(
                                fontSize: 14,
                                height: 2.0,
                                color: Colors.white,
                                letterSpacing: 2),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  alignment: Alignment.topCenter,
                ),
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: ElevatedButton(
                    child: const Text('Search'),
                    onPressed: () {
                      setState(() {
                        for (Graph g in loadedGraphsList) {
                          if (g.isInFocus) {
                            String sName = searchedNodeNameController.text;
                            Map infoMap = g.getInfoByName(sName);
                            if (infoMap['Type'] != '') {
                              changeSelectedPoint(g, sName);
                              zoomLevel = 15;
                              mapController.move(focusLatLng, zoomLevel);
                            }
                          }
                        }
                      });
                      Navigator.of(context).pop();
                    },
                  ),
                ),
              )
            ],
          ),
        ),
      );
    });
  }

  @override
  void initState() {
    qGraph = QGraph(changeSelectedPoint: changeSelectedPoint);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    if (!isQGloaded) {
      getQgraph();
    }
    return Card(
      child: Row(
        children: [
          Flexible(
            child: FlutterMap(
              mapController: mapController,
              options: MapOptions(
                  center: centerLatLng,
                  zoom: zoomLevel,
                  onTap: (tapPosition, point) {
                    if (isPolygonCreationStarted) {
                      polygonPoints.add(point);
                    }
                  }),
              children: [
                TileLayer(
                  urlTemplate: getTileURL(),
                  subdomains: const ['a', 'b', 'c'],
                ),
                PolygonLayer(
                  polygons: isPolygonCreationStarted
                      ? [
                          Polygon(
                              points: polygonPoints,
                              borderStrokeWidth: 2.0,
                              borderColor: Colors.black87)
                        ]
                      : [],
                ),
                PolylineLayer(polylines: [...getShps(line: true)]),
                MarkerLayer(markers: [...getShps(point: true)]),
                zoomController(),
                isDrawerOpened
                    ? glassMorphic(
                        Column(
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                child: Column(
                                  children: [
                                    pushNpullDrawer(),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: mapSwitcher(),
                                        ),
                                        isQGloaded
                                            ? Align(
                                                alignment:
                                                    Alignment.centerRight,
                                                child: IconButton(
                                                  onPressed:
                                                      !isPolygonCreationStarted
                                                          ? () {
                                                              showDialog(
                                                                context:
                                                                    context,
                                                                builder:
                                                                    (BuildContext
                                                                        context) {
                                                                  return filterDialog();
                                                                },
                                                              );
                                                            }
                                                          : null,
                                                  icon: const Icon(
                                                    Icons.filter_alt,
                                                    color: Colors.blue,
                                                  ),
                                                ),
                                              )
                                            : const SizedBox(),
                                        isQGloaded
                                            ? Align(
                                                alignment:
                                                    Alignment.centerRight,
                                                child: IconButton(
                                                  onPressed: () {
                                                    showDialog(
                                                      context: context,
                                                      builder: (BuildContext
                                                          context) {
                                                        return searchDialog();
                                                      },
                                                    );
                                                  },
                                                  icon: const Icon(
                                                    Icons.search,
                                                    color: Colors.blue,
                                                  ),
                                                ),
                                              )
                                            : const SizedBox(),
                                      ],
                                    ),
                                    loadedGraphsList.isEmpty
                                        ? const Padding(
                                            padding: EdgeInsets.all(8.0),
                                            child: SizedBox(
                                                width: 12,
                                                height: 12,
                                                child:
                                                    CircularProgressIndicator()),
                                          )
                                        : const SizedBox(),
                                    ...loadedGraphsList
                                        .map((e) => graphWidget(e)),
                                    isSlectionStarted
                                        ? nodeSelections()
                                        : const SizedBox(),
                                    isloading
                                        ? const Padding(
                                            padding: EdgeInsets.all(8.0),
                                            child: SizedBox(
                                              width: 12,
                                              height: 12,
                                              child:
                                                  CircularProgressIndicator(),
                                            ),
                                          )
                                        : const SizedBox(),
                                  ],
                                ),
                              ),
                            ),
                            pointDetails(),
                          ],
                        ),
                        width: 300,
                      )
                    : pushNpullDrawer(),
                isPolygonCreationStarted
                    ? Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                  icon: const Icon(
                                    Icons.cancel,
                                    color: Colors.redAccent,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      stopPolygonCreation();
                                      polygonPoints = <LatLng>[];
                                    });
                                  }),
                              IconButton(
                                  icon: const Icon(
                                    Icons.add_circle,
                                    color: Colors.greenAccent,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      stopPolygonCreation();
                                      isPolygonFilterEnabled = true;
                                      for (Graph g in loadedGraphsList) {
                                        if (g.isInFocus) {
                                          getNodesInPolygon(g);
                                        }
                                      }
                                    });
                                  }),
                            ],
                          ),
                        ),
                      )
                    : const SizedBox(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
