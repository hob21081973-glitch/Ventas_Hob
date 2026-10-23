import 'dart:io';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class PdfHelper {

  /// Genera, procesa y guarda el reporte en la carpeta Descargas de Android
  static Future<String?> generarYGuardarReporteGeneral({
    required int pedidoInicial,
    required int pedidoFinal,
    required List<Map<String, dynamic>> listaProductosVendidos,
    required String nombreArchivo,
  }) async {
    try {
      // 1. Ordenar los productos de mayor a menor valor total vendido
      listaProductosVendidos.sort((a, b) {
        double totalA = (a['valorTotal'] ?? 0.0).toDouble();
        double totalB = (b['valorTotal'] ?? 0.0).toDouble();
        return totalB.compareTo(totalA); // Orden descendente
      });

      // 2. Crear el documento PDF
      final pdf = pw.Document();

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.letter,
          margin: const pw.EdgeInsets.all(32),
          build: (pw.Context context) {
            return [
              // Encabezado del Reporte
              pw.Header(
                level: 0,
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Reporte General de Pedidos y Ventas',
                        style: pw.TextStyle(
                            fontSize: 18, fontWeight: pw.FontWeight.bold)),
                    pw.Text('Fecha: ${DateTime.now().toLocal().toString().split(' ')[0]}',
                        style: const pw.TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              pw.SizedBox(height: 10),

              // Información del Rango de Pedidos
              pw.Container(
                padding: const pw.all(8),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey400),
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                  children: [
                    pw.Text('Pedido Inicial: $pedidoInicial',
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                    pw.Text('Pedido Final: $pedidoFinal',
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  ],
                ),
              ),
              pw.SizedBox(height: 20),

              // Sección: Productos Vendidos
              pw.Text('Productos Vendidos (Ordenados por Valor Total)',
                  style: pw.TextStyle(
                      fontSize: 14, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 10),

              // Tabla de Productos
              pw.Table.fromTextArray(
                context: context,
                headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
                headerHeight: 25,
                cellHeight: 30,
                cellAlignment: pw.Alignment.centerLeft,
                headerStyle: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, fontSize: 10),
                cellStyle: const pw.TextStyle(fontSize: 10),
                headers: ['Producto', 'Cantidad Total', 'Valor Total'],
                data: listaProductosVendidos.map((producto) {
                  return [
                    producto['nombre'] ?? 'Sin nombre',
                    producto['cantidad'].toString(),
                    '\$${(producto['valorTotal'] ?? 0.0).toStringAsFixed(2)}',
                  ];
                }).toList(),
              ),
            ];
          },
        ),
      );

      // 3. Guardar el archivo en bytes
      final Uint8List pdfBytes = await pdf.save();

      // 4. Gestionar permisos y almacenamiento en Android
      var status = await Permission.storage.request();

      if (status.isGranted || Platform.isAndroid) {
        Directory? directorio;

        if (Platform.isAndroid) {
          // Apunta directo a la carpeta Descargas pública de Android
          directorio = Directory('/storage/emulated/0/Download');
          if (!await directorio.exists()) {
            directorio = await getExternalStorageDirectory();
          }
        } else {
          directorio = await getApplicationDocumentsDirectory();
        }

        final rutaCompleta = '${directorio?.path}/$nombreArchivo';
        final archivo = File(rutaCompleta);
        await archivo.writeAsBytes(pdfBytes);

        return rutaCompleta; // Retorna la ruta exitosa
      } else {
        throw Exception('Permisos de almacenamiento denegados.');
      }
    } catch (e) {
      print('Error al generar o guardar el PDF: $e');
      return null;
    }
  }
}
