import 'dart:convert';
import 'package:latlong2/latlong.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/material.dart';

Map lInfo = {
  'C4': [const Color(0xFF003F5C), 1],
  'C3': [const Color(0xFF58508D), 2.5],
  'C2': [const Color(0xFFBC5090), 3.5],
  'C1': [const Color(0xFFFF6361), 4.5],
  'Call': [const Color.fromARGB(255, 247, 38, 35), 2],
};

Map pInfo = {
  'Drop point': [const Color(0xFF581845), 4],
  'PLR': [const Color(0xFF900C3F), 6.5],
  'SEC': [const Color(0xFFC70039), 10],
  'PRM': [const Color(0xFFFF5733), 13.5],
  'Exchange': [const Color(0xFFFFC300), 17]
};

class Graph {
  bool isInFocus = false;
  String graphType = 'ABSTRACT';
  bool showLines = true;
  bool showPoints = true;
  bool isLoaded = false;
  String selectedPoint = 'E0';
  int filterChangeID = 4014;

  Map edges = {};
  Map nodes = {};
  List<String> functionKeys = <String>[
    'Network Path',
    'E2E',
    'Cicuits',
    'Discrepancies'
  ];
  List<Marker> qpoints = <Marker>[];
  List<Polyline> qlines = <Polyline>[];
  List filteredPoints = [];

  final Function changeSelectedPoint;

  Map getInfoByName(String name) {
    List coords = [];
    String type = '';
    String ecc = '';
    String ps = '';
    for (var point in nodes['features']) {
      if (name == point['properties']['Name']) {
        coords = point['geometry']['coordinates'];
        type = point['properties']['Type'];
        if (type == 'Drop point') {
          ecc = point['properties']['ECC'];
          ps = point['properties']['PS'];
        }
      }
    }
    return {'Name': name, 'Coords': coords, 'Type': type, 'ECC': ecc, 'PS': ps};
  }

  Marker getPointMarker(var point) {
    var coords = point['geometry']['coordinates'];
    return Marker(
      width: pInfo[point['properties']['Type']][1],
      height: pInfo[point['properties']['Type']][1],
      point: LatLng(coords[1], coords[0]),
      builder: (BuildContext context) => GestureDetector(
        onLongPress: () {
          changeSelectedPoint(this, point['properties']['Name']);
        },
        onTap: () {
          changeSelectedPoint(this, point['properties']['Name']);
        },
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: pInfo[point['properties']['Type']][0],
          ),
        ),
      ),
    );
  }

  bool isPointAllowed(var point, Map filter) {
    bool typeCheck = filter[point['properties']['Type']];
    List filteNodeNames = filter['Nodes'] as List;

    if (filteNodeNames.isNotEmpty &&
        !filteNodeNames.contains(point['properties']['Name'])) {
      return false;
    }

    if (point['properties']['Type'] == 'Drop point') {
      bool eccCheck = filter['ECC'][point['properties']['ECC']];
      bool psCheck = filter['PS'][point['properties']['PS']];

      if (typeCheck && eccCheck && psCheck) {
        return true;
      } else {
        return false;
      }
    } else {
      if (typeCheck) {
        return true;
      } else {
        return false;
      }
    }
  }

  List<Marker> qPoints({required Map filter, required int filterChangeID}) {
    if (this.filterChangeID < filterChangeID) {
      qpoints = <Marker>[];
      filteredPoints = [];
      for (var point in nodes['features']) {
        if (isPointAllowed(point, filter)) {
          qpoints.add(getPointMarker(point));
        } else {
          filteredPoints.add(point);
        }
      }
      this.filterChangeID = filterChangeID;
      addNewSelectionMarker();
      return qpoints;
    } else {
      return qpoints;
    }
  }

  void addNewSelectionMarker() {
    Map infomap = getInfoByName(selectedPoint);
    Marker seletedMarker = Marker(
      width: pInfo[infomap['Type']][1] + 6,
      height: pInfo[infomap['Type']][1] + 6,
      point: LatLng(infomap['Coords'][1], infomap['Coords'][0]),
      builder: (BuildContext context) => GestureDetector(
        onTap: () {},
        child: Container(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.blueAccent,
          ),
          child: Icon(
            Icons.circle,
            color: Colors.yellowAccent,
            size: pInfo[infomap['Type']][1] + 3,
          ),
        ),
      ),
    );
    qpoints.add(seletedMarker);
  }

  void removePreviousSelectionMarker() {
    qpoints.removeLast();
  }

  bool isLineAllowed(points) {
    for (var point in filteredPoints) {
      double p1x = point['geometry']['coordinates'][1];
      double p1y = point['geometry']['coordinates'][0];

      double p2x = points[0][1];
      double p2y = points[0][0];

      double p3x = points[1][1];
      double p3y = points[1][0];

      if ((p1x == p2x && p1y == p2y) || (p1x == p3x && p1y == p3y)) {
        return false;
      }
    }
    return true;
  }

  List<Polyline> qLines({required Map filter, required int filterChangeID}) {
    if (this.filterChangeID < filterChangeID) {
      qlines = <Polyline>[];
      for (var line in edges['features']) {
        List<LatLng> points = <LatLng>[];
        for (var point in line['geometry']['coordinates']) {
          points.add(LatLng(point[1], point[0]));
        }
        qlines.add(
          Polyline(
            points: points,
            color: lInfo[line['properties']['Type']][0],
            strokeWidth: lInfo[line['properties']['Type']][1],
          ),
        );
      }
      return qlines;
    } else {
      return qlines;
    }
  }

  Graph({required this.changeSelectedPoint});

  void j2g(var res) {
    var jres = json.decode(res.body) as Map;
    edges = jres['edges'];
    nodes = jres['nodes'];
  }
}

class QGraph extends Graph {
  bool isReduced = false;
  late Graph rGraph;

  QGraph({required super.changeSelectedPoint}) {
    graphType = 'UNDIRECTED';
    functionKeys += ['Direct'];
    isInFocus = true;
    rGraph = Graph(changeSelectedPoint: changeSelectedPoint);
  }
}

class RGraph extends Graph {
  RGraph({required super.changeSelectedPoint}) {
    graphType = 'DIRECTED';
    functionKeys += ['PLR Centrality', 'ALL Centrality'];
  }

  @override
  List<Polyline> qLines({required Map filter, required int filterChangeID}) {
    if (this.filterChangeID < filterChangeID) {
      qpoints = qPoints(filter: filter, filterChangeID: filterChangeID);
      qlines = <Polyline>[];
      for (var line in edges['features']) {
        if (isLineAllowed(line['geometry']['coordinates'])) {
          List<LatLng> points = <LatLng>[];
          for (var point in line['geometry']['coordinates']) {
            points.add(LatLng(point[1], point[0]));
          }
          qlines.add(
            Polyline(
              points: points,
              color: lInfo[line['properties']['Type']][0],
              strokeWidth: lInfo[line['properties']['Type']][1],
            ),
          );
        }
      }
      return qlines;
    } else {
      return qlines;
    }
  }
}

class CRGraph extends Graph {
  CRGraph({required super.changeSelectedPoint}) {
    graphType = 'CENTRALITY';
    functionKeys += ['Reverse Direct'];
  }

  @override
  List<Polyline> qLines({required Map filter, required int filterChangeID}) {
    if (this.filterChangeID < filterChangeID) {
      qpoints = qPoints(filter: filter, filterChangeID: filterChangeID);
      qlines = <Polyline>[];
      for (var line in edges['features']) {
        if (isLineAllowed(line['geometry']['coordinates'])) {
          List<LatLng> points = <LatLng>[];
          for (var point in line['geometry']['coordinates']) {
            points.add(LatLng(point[1], point[0]));
          }
          qlines.add(
            Polyline(
              points: points,
              color: lInfo[line['properties']['Type']][0],
              strokeWidth: lInfo[line['properties']['Type']][1],
            ),
          );
        }
      }
      return qlines;
    } else {
      return qlines;
    }
  }
}

class NetworkPathGraph extends Graph {
  NetworkPathGraph({required super.changeSelectedPoint}) {
    graphType = 'PATH';
  }
}

class E2EGraph extends Graph {
  E2EGraph({required super.changeSelectedPoint}) {
    graphType = 'E2E';
  }
}

class CircuitGraph extends Graph {
  CircuitGraph({required super.changeSelectedPoint}) {
    graphType = 'Circuits';
  }
}

class ReversedReducedGraph extends Graph {
  ReversedReducedGraph({required super.changeSelectedPoint}) {
    graphType = 'Reversed';
  }
}
