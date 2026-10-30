import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../database_helper.dart';

class VistaExportarPdf extends StatefulWidget {
  const VistaExportarPdf({super.key});

  @override
  State<VistaExportarPdf> createState() => _VistaExportarPdfState();
}

class _VistaExportarPdfState extends State<VistaExportarPdf> {
  DateTime? fechaInicio;
  DateTime? fechaFin;

  Future<void> _exportarGeneralPdf() async {
    final db = await DatabaseHelper.instance.database;
    final pedidos = await db.query('pedidos', orderBy: 'id DESC');

    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Text('Reporte General de Ventas - APP VENTAS HOB', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
            ),
            pw.SizedBox(height: 10),
            pw.Table.fromTextArray(
              headers: ['N° Pedido', 'Cliente', 'Fecha', 'Semana', 'Total'],
              data: pedidos.map((p) {
                return [
                  p['numero_pedido'].toString(),
                  p['cliente'].toString(),
                  p['fecha'].toString(),
                  p['semana']?.toString() ?? 'S/A',
                  'L ${(p['total'] as num).toStringAsFixed(2)}',
                ];
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
      await Printing.sharePdf(bytes: bytes, filename: 'Reporte_General_Ventas.pdf');
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reporte General generado con éxito')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al generar Reporte General: $e')));
    }
  }

  void _abrirDialogoReporteCliente() {
    String semanaFiltro = '';
    Map<String, dynamic>? pedidoSeleccionado;
    TextEditingController cantidadRealCtrl = TextEditingController();
    TextEditingController incidenciaCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return Dialog.fullscreen(
              child: Scaffold(
                appBar: AppBar(
                  title: const Text('Reporte Gral por Cliente e Incidencias'),
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                body: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('1. Buscar por Semana o Cliente (opcional):', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'Escribe número de semana o palabra clave...',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (val) {
                          setStateDialog(() {
                            semanaFiltro = val.trim();
                          });
                        },
                      ),
                      const SizedBox(height: 14),
                      const Text('2. Selecciona el Pedido a gestionar:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      
                      Expanded(
                        flex: 3,
                        child: FutureBuilder(
                          future: DatabaseHelper.instance.database.then((db) {
                            if (semanaFiltro.isEmpty) {
                              return db.query('pedidos', orderBy: 'id DESC', limit: 50);
                            } else {
                              return db.query('pedidos', 
                                where: 'numero_pedido LIKE ? OR cliente LIKE ? OR semana LIKE ?', 
                                whereArgs: ['%$semanaFiltro%', '%$semanaFiltro%', '%$semanaFiltro%'],
                                orderBy: 'id DESC'
                              );
                            }
                          }),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                            
                            final List pedidos = (snapshot.data ?? []) as List;

                            if (pedidos.isEmpty) {
                              return const Center(child: Text('No se encontraron pedidos con ese filtro.'));
                            }
                            return ListView.builder(
                              itemCount: pedidos.length,
                              itemBuilder: (context, index) {
                                final p = pedidos[index] as Map<String, dynamic>;
                                bool esSeleccionado = pedidoSeleccionado != null && pedidoSeleccionado!['id'] == p['id'];
                                return Card(
                                  color: esSeleccionado ? Colors.indigo.shade50 : Colors.white,
                                  child: ListTile(
                                    title: Text('${p['numero_pedido']} - ${p['cliente']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                                    subtitle: Text('Total Teórico: L ${(p['total'] as num).toStringAsFixed(2)} | Semana: ${p['semana'] ?? 'S/A'}'),
                                    trailing: esSeleccionado ? const Icon(Icons.check_circle, color: Colors.indigo) : const Icon(Icons.radio_button_unchecked),
                                    onTap: () {
                                      setStateDialog(() {
                                        pedidoSeleccionado = p;
                                        if (cantidadRealCtrl.text.isEmpty) {
                                          cantidadRealCtrl.text = p['total'].toString();
                                        }
                                      });
                                    },
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                      
                      const SizedBox(height: 10),

                      if (pedidoSeleccionado != null) ...[
                        Expanded(
                          flex: 4,
                          child: SingleChildScrollView(
                            child: Card(
                              elevation: 3,
                              margin: EdgeInsets.zero,
                              child: Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Gestionando: ${pedidoSeleccionado!['numero_pedido']} (${pedidoSeleccionado!['cliente']})',
                                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo, fontSize: 15)),
                                    const SizedBox(height: 12),
                                    TextField(
                                      controller: cantidadRealCtrl,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(
                                        labelText: 'Valor / Monto Real Entregado',
                                        border: OutlineInputBorder(),
                                        prefixText: 'L ',
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    TextField(
                                      controller: incidenciaCtrl,
                                      maxLines: 2,
                                      decoration: const InputDecoration(
                                        labelText: 'Incidencias / Comentarios (Devoluciones, faltantes, etc.)',
                                        border: OutlineInputBorder(),
                                        hintText: 'Ej. Hubo devolución de unidades o ajuste...',
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    SizedBox(
                                      width: double.infinity,
                                      child: ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.indigo,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(vertical: 14),
                                        ),
                                        icon: const Icon(Icons.picture_as_pdf),
                                        label: const Text('Generar y Descargar PDF con Incidencia'),
                                        onPressed: () async {
                                          await _generarPdfIncidenciaIndividual(
                                            pedidoSeleccionado!,
                                            cantidadRealCtrl.text,
                                            incidenciaCtrl.text,
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _generarPdfIncidenciaIndividual(Map<String, dynamic> pedido, String valorReal, String incidencia) async {
    final db = await DatabaseHelper.instance.database;
    final productosDb = await db.query('productos');
    final clientesDb = await db.query('clientes');

    Map<String, String> codigosProdMap = {};
    for (var prod in productosDb) {
      codigosProdMap[prod['nombre'].toString().trim()] = prod['codigo'].toString().trim();
    }

    Map<String, String> codigosClientMap = {};
    for (var cli in clientesDb) {
      codigosClientMap[cli['nombre'].toString().trim()] = cli['codigo'].toString().trim();
    }

    String nombreCliente = pedido['cliente'].toString().trim();
    String codigoCliente = codigosClientMap[nombreCliente] ?? 'S/C';

    final pdf = pw.Document();
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          List<pw.Widget> detalleWidgets = [];
          String prodString = pedido['productos_json'].toString();
          List<String> items = prodString.split(';');
          for (var item in items) {
            if (item.trim().isEmpty) continue;
            
            int idxCant = item.lastIndexOf('(x');
            if (idxCant == -1) continue;

            String nombreBruto = item.substring(0, idxCant).trim();
            int cant = int.parse(item.substring(idxCant + 2).replaceAll(')', '').trim());
            
            String nombreProd = nombreBruto;
            String detalleProd = '';
            if (nombreBruto.contains('[') && nombreBruto.endsWith(']')) {
              int startIdx = nombreBruto.lastIndexOf('[');
              nombreProd = nombreBruto.substring(0, startIdx).trim();
              detalleProd = nombreBruto.substring(startIdx + 1, nombreBruto.length - 1).trim();
            }
            String codigoProd = codigosProdMap[nombreProd] ?? 'S/C';

            detalleWidgets.add(
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 10, bottom: 4),
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('[$codigoProd] ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10)),
                    pw.Expanded(
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text('$nombreProd (x$cant)', style: const pw.TextStyle(fontSize: 10)),
                          if (detalleProd.isNotEmpty)
                            pw.Padding(
                              padding: const pw.EdgeInsets.only(left: 4.0, top: 1.0),
                              child: pw.Text('[$detalleProd]', style: pw.TextStyle(fontSize: 9, fontStyle: pw.FontStyle.italic, color: PdfColors.grey700)),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Header(
                level: 0,
                child: pw.Text('Reporte de Incidencias y Entrega - VENTAS HOB', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
              ),
              pw.SizedBox(height: 10),
              pw.Text('Número de Pedido: ${pedido['numero_pedido']}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
              pw.Text('Cliente: [$codigoCliente] $nombreCliente', style: const pw.TextStyle(fontSize: 12)),
              pw.Text('Semana: ${pedido['semana'] ?? 'Sin Asignar'} | Fecha: ${pedido['fecha']}', style: const pw.TextStyle(fontSize: 12)),
              pw.Divider(height: 20),
              pw.Text('Detalle del Pedido:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 6),
              ...detalleWidgets,
              pw.Divider(height: 20),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Total Teórico del Pedido:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.Text('L ${(pedido['total'] as num).toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                ],
              ),
              pw.SizedBox(height: 6),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Valor Real Entregado:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.indigo700)),
                  pw.Text('L $valorReal', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.indigo700)),
                ],
              ),
              pw.SizedBox(height: 15),
              pw.Text('Incidencias / Observaciones Registradas:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 4),
              pw.Container(
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400)),
                child: pw.Text(incidencia.isEmpty ? 'Ninguna incidencia registrada.' : incidencia, style: const pw.TextStyle(fontSize: 11)),
              ),
            ],
          );
        },
      ),
    );

    try {
      Uint8List bytes = await pdf.save();
      String nombreArchivo = "Incidencia_${pedido['numero_pedido'].toString().replaceAll('#', '')}_$nombreCliente.pdf";
      await Printing.sharePdf(bytes: bytes, filename: nombreArchivo);
      
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF de incidencia generado: $nombreArchivo')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al generar PDF: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Exportar Reportes PDF'), backgroundColor: Colors.indigo, foregroundColor: Colors.white),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Card(
            elevation: 3,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Reporte General de Ventas', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text('Exporta el listado completo de todos los pedidos registrados.', style: TextStyle(fontSize: 13, color: Colors.grey)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
                      icon: const Icon(Icons.picture_as_pdf),
                      label: const Text('Exportar General'),
                      onPressed: _exportarGeneralPdf,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 15),
          Card(
            elevation: 3,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Reporte Gral por Cliente e Incidencias', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text('Selecciona una semana o pedido para registrar valor entregado y comentarios de incidencias.', style: TextStyle(fontSize: 13, color: Colors.grey)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
                      icon: const Icon(Icons.assignment_turned_in),
                      label: const Text('Gestionar y Exportar por Cliente'),
                      onPressed: _abrirDialogoReporteCliente,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
