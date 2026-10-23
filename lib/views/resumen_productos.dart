import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../database_helper.dart';

class VistaResumenProductos extends StatefulWidget {
  const VistaResumenProductos({super.key});

  @override
  State<VistaResumenProductos> createState() => _VistaResumenProductosState();
}

class _VistaResumenProductosState extends State<VistaResumenProductos> {
  String tipoVista = 'unidades';

  Future<void> _generarReporteProductosPdf() async {
    final db = await DatabaseHelper.instance.database;
    final pedidos = await db.query('pedidos');
    final productosDb = await db.query('productos');

    Map<String, double> preciosMap = {};
    Map<String, String> codigosMap = {};
    for (var prod in productosDb) {
      String nombreProd = prod['nombre'].toString().trim();
      preciosMap[nombreProd] = (prod['precio'] as num).toDouble();
      codigosMap[nombreProd] = prod['codigo'].toString().trim();
    }

    Map<String, int> conteoUnidades = {};
    Map<String, double> valorVentas = {};

    for (var p in pedidos) {
      String prodString = p['productos_json'].toString();
      List<String> items = prodString.split(';');
      for (var item in items) {
        if (item.trim().isEmpty) continue;
        try {
          int idxCant = item.lastIndexOf('(x');
          if (idxCant == -1) continue;

          String nombreBruto = item.substring(0, idxCant).trim();
          int cant = int.parse(item.substring(idxCant + 2).replaceAll(')', '').trim());
          
          String nombreLimpio = nombreBruto;
          if (nombreBruto.contains('[')) {
            nombreLimpio = nombreBruto.substring(0, nombreBruto.lastIndexOf('[')).trim();
          }

          conteoUnidades[nombreLimpio] = (conteoUnidades[nombreLimpio] ?? 0) + cant;
          double precioUnit = preciosMap[nombreLimpio] ?? 0.0;
          valorVentas[nombreLimpio] = (valorVentas[nombreLimpio] ?? 0.0) + (precioUnit * cant);
        } catch (_) {}
      }
    }

    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Text('Reporte Acumulado por Productos - APP VENTAS HOB', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
            ),
            pw.SizedBox(height: 10),
            pw.Table.fromTextArray(
              headers: ['Código', 'Producto', 'Unidades', 'Total Ventas'],
              data: conteoUnidades.entries.map((e) {
                String prod = e.key;
                int unidades = e.value;
                double valor = valorVentas[prod] ?? 0.0;
                String codigo = codigosMap[prod] ?? 'S/C';
                return [codigo, prod, unidades.toString(), 'L ${valor.toStringAsFixed(2)}'];
              }).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.indigo700),
              cellStyle: const pw.TextStyle(fontSize: 10),
            ),
          ];
        },
      ),
    );

    try {
      Uint8List bytes = await pdf.save();
      await Printing.sharePdf(bytes: bytes, filename: 'Reporte_Acumulado_Productos.pdf');
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reporte de productos generado con éxito')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al generar PDF de productos: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Resumen por Producto'), 
        backgroundColor: Colors.indigo, 
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: 'Descargar PDF de Productos',
            onPressed: _generarReporteProductosPdf,
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: DatabaseHelper.instance.database.then((db) => db.query('pedidos')),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final pedidos = snapshot.data!;
          
          return FutureBuilder<List<Map<String, dynamic>>>(
            future: DatabaseHelper.instance.database.then((db) => db.query('productos')),
            builder: (context, prodSnapshot) {
              final productosDb = prodSnapshot.data ?? [];
              Map<String, double> preciosMap = {};
              for (var prod in productosDb) {
                preciosMap[prod['nombre'].toString().trim()] = (prod['precio'] as num).toDouble();
              }

              Map<String, int> conteoUnidades = {};
              Map<String, double> valorVentas = {};

              for (var p in pedidos) {
                String prodString = p['productos_json'].toString();
                List<String> items = prodString.split(';');
                for (var item in items) {
                  if (item.trim().isEmpty) continue;
                  try {
                    int idxCant = item.lastIndexOf('(x');
                    if (idxCant == -1) continue;

                    String nombreBruto = item.substring(0, idxCant).trim();
                    int cant = int.parse(item.substring(idxCant + 2).replaceAll(')', '').trim());
                    
                    String nombreLimpio = nombreBruto;
                    if (nombreBruto.contains('[')) {
                      nombreLimpio = nombreBruto.substring(0, nombreBruto.lastIndexOf('[')).trim();
                    }

                    conteoUnidades[nombreLimpio] = (conteoUnidades[nombreLimpio] ?? 0) + cant;
                    double precioUnit = preciosMap[nombreLimpio] ?? 0.0;
                    valorVentas[nombreLimpio] = (valorVentas[nombreLimpio] ?? 0.0) + (precioUnit * cant);
                  } catch (_) {}
                }
              }

              var listaOrdenadaUnidades = conteoUnidades.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value));
              var listaOrdenadaValor = valorVentas.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value));

              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Ranking de Productos', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ToggleButtons(
                        isSelected: [tipoVista == 'unidades', tipoVista == 'valor'],
                        onPressed: (index) {
                          setState(() {
                            tipoVista = index == 0 ? 'unidades' : 'valor';
                          });
                        },
                        constraints: const BoxConstraints(minHeight: 30, minWidth: 80),
                        children: const [
                          Text('Unidades', style: TextStyle(fontSize: 12)),
                          Text('Valor (L)', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                  const Divider(),
                  if (tipoVista == 'unidades') ...[
                    if (listaOrdenadaUnidades.isEmpty)
                      const Center(child: Text('No hay datos'))
                    else
                      ...listaOrdenadaUnidades.map((e) => ListTile(
                        title: Text(e.key, style: const TextStyle(fontSize: 15)),
                        trailing: Text('${e.value}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.indigo)),
                      )),
                  ] else ...[
                    if (listaOrdenadaValor.isEmpty)
                      const Center(child: Text('No hay datos'))
                    else
                      ...listaOrdenadaValor.map((e) => ListTile(
                        title: Text(e.key, style: const TextStyle(fontSize: 15)),
                        trailing: Text('L ${e.value.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.indigo)),
                      )),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }
}
