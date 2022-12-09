const String basePoint = 'https://softel-backend.herokuapp.com/';
const String getQgraphURL = 'api/graph/quick_graph';
const String getRgraphURL = 'api/graph/reduce';
const String getNodesInPolygonURL = 'api/graph/withinpoly';
const String getGraphDiscrepanciesURL = 'api/graph/hl_discrepancies';

String getCgraphURL(String relocate, int maxAttachments) {
  return 'api/graph/op_cen/$relocate/$maxAttachments';
}

String getNetworkPathURL(String origin) {
  return 'api/graph/sh_pth/$origin';
}

String getE2EURL(String caller, String reciever) {
  return 'api/graph/e2e/$caller/$reciever';
}

String getCircuitURL(String nodeName) {
  return '/api/graph/allcircuits/$nodeName';
}

String getReversedRGraphURL(String origin) {
  return '/api/graph/reverse_reduction/$origin';
}
