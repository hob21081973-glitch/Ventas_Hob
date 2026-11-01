import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package0/url_launcher/url_launcher.dart';
import '../database_helper.dart';
import '../main.dart';

class VistaHistorialPedidos extends StatefulWidget {
  const VistaHistorialPedidos({super.key});

  @override
  State<VistaHistorialPedidos> createState() => _VistaHistorialPedidosState();
}

class _VistaHistorialPedidosState extends State<VistaHistorialPedidos> {
  Set<int> pedidosSeleccionadosIds = {};

  // 1. Diálogo de confirmación para reseteo
  Future<void> _resetearConteo() async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmar reseteo'),
        content: const Text('¿Estás seguro de que deseas eliminar y resetear todo el historial de pedidos?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sí, eliminar'),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    final db = await DatabaseHelper.instance.database;
    await db.delete('pedidos');
    pedidosSeleccionadosIds.clear();
    setState(() {});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Conteo de pedidos reseteado a 0')),
    );
  }

  void _enviarWhatsApp(String cliente, String productos, double total) async {
    String mensaje = "Hola $cliente, tu pedido consta de: $productos. Total: L ${total.toStringAsFixed(2)}. ¡Gracias por tu compra!";
    final url = Uri.parse("https://wa.me/?text=${Uri.encodeComponent(mensaje)}");
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _generarPdfPedidoIndividual(Map<String, dynamic> pedido) async {
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
            String texto = item.trim();
            int cant = 1;
            if (texto.contains('(x')) {
              var splitCant = texto.split('(x');
              texto = splitCant[0].trim();
              try {
                cant = int.parse(splitCant[1].replaceAll(')', '').trim());
              } catch (_) {}
            }
            String nombreProd = texto;
            String detalleProd = '';
            if (texto.contains('[') && texto.endsWith(']')) {
              int startIdx = texto.lastIndexOf('[');
              nombreProd = texto.substring(0, startIdx).trim();
              detalleProd = texto.substring(startIdx + 1, texto.length - 1).trim();
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
                child: pw.Text('Comprobante de Pedido - APP VENTAS HOB', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
              ),
              pw.SizedBox(height: 10),
              pw.Text('Número de Pedido: ${pedido['numero_pedido']}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
              pw.Text('Cliente: [$codigoCliente] $nombreCliente', style: const pw.TextStyle(fontSize: 12)),
              pw.Text('Fecha: ${pedido['fecha']}', style: const pw.TextStyle(fontSize: 12)),
              pw.Text('Semana: ${pedido['semana'] ?? 'Sin Asignar'}', style: const pw.TextStyle(fontSize: 12)),
              pw.Divider(height: 20),
              pw.Text('Detalle de Productos:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 6),
              ...detalleWidgets,
              pw.Divider(height: 20),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Total del Pedido:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.Text('L ${(pedido['total'] as num).toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                ],
              ),
            ],
          );
        },
      ),
    );
    try {
      Uint8List bytes = await pdf.save();
      String nombreArchivo = "Pedido_${pedido['numero_pedido'].toString().replaceAll('#', '')}_$nombreCliente.pdf";
      await Printing.sharePdf(bytes: bytes, filename: nombreArchivo);
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF generado: $nombreArchivo')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al generar PDF: $e')));
    }
  }

  void _mostrarAsignarSemanaDialog() {
    if (pedidosSeleccionadosIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Seleccione al menos un pedido')));
      return;
    }
    TextEditingController semanaCtrl = TextEditingController(text: 'Semana 01');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Asignar a Semana'),
        content: TextField(
          controller: semanaCtrl,
          decoration: const InputDecoration(labelText: 'Ej. Semana 01, Semana 02...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () async {
              String sem = semanaCtrl.text.trim();
              if (sem.isNotEmpty) {
                final db = await DatabaseHelper.instance.database;
                for (int id in pedidosSeleccionadosIds) {
                  await db.update('pedidos', {'semana': sem}, where: 'id = ?', whereArgs: [id]);
                }
                pedidosSeleccionadosIds.clear();
                setState(() {});
                if (!mounted) return;
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Pedidos asignados a $sem')));
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  void _mostrarMenuOpciones(Map<String, dynamic> pedido) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.picture_as_pdf, color: Colors.indigo),
              title: const Text('Generar PDF por Pedido'),
              onTap: () {
                Navigator.pop(context);
                _generarPdfPedidoIndividual(pedido);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.blue),
              title: const Text('Editar Pedido (Modificar en Crear)'),
              onTap: () {
                Navigator.pop(context);
                _mandarAEditar(pedido);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Eliminar Pedido'),
              onTap: () async {
                Navigator.pop(context);
                final db = await DatabaseHelper.instance.database;
                await db.delete('pedidos', where: 'id = ?', whereArgs: [pedido['id']]);
                setState(() {});
              },
            ),
          ],
        );
      },
    );
  }

  void _mandarAEditar(Map<String, dynamic> pedido) async {
    List> productosParsed = [];
    String prodString = pedido['productos_json'].toString();
    
    List<String> items = prodString.split(';');
    for (var item in items) {
      if (item.trim().isEmpty) continue;
      try {
        String texto = item.trim();
        int cant = 1;
        if (texto.contains('(x')) {
          var splitCant = texto.split('(x');
          texto = splitCant[0].trim();
          cant = int.parse(splitCant[1].replaceAll(')', '').trim());
        }
        String nombre = texto;
        String comentario = '';
        if (texto.contains('[') && texto.endsWith(']')) {
          int startIdx = texto.lastIndexOf('[');
          nombre = texto.substring(0, startIdx).trim();
          comentario = texto.substring(startIdx + 1, texto.length - 1).trim();
        }
        final db = await DatabaseHelper.instance.database;
        var prodDb = await db.query('productos', where: 'nombre = ?', whereArgs: [nombre], limit: 1);
        double precio = 0.0;
        if (prodDb.isNotEmpty) {
          precio = (prodDb.first['precio'] as num).toDouble();
        }
        productosParsed.add({
          'nombre': nombre,
          'precio': precio,
          'cantidad': cant,
          'comentario': comentario,
        });
      } catch (_) {}
    }
    final mainState = context.findAncestorStateOfType<MenuPrincipalState>();
    if (mainState != null) {
      mainState.cargarPedidoParaEditar(
        pedido['id'],
        pedido['numero_pedido'].toString(),
        pedido['cliente'].toString(),
        productosParsed,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Historial de Pedidos'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        actions: [
          if (pedidosSeleccionadosIds.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.bookmark_add),
              tooltip: 'Asignar Semana',
              onPressed: _mostrarAsignarSemanaDialog,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Resetear Conteo',
            onPressed: _resetearConteo,
          )
        ],
      ),
      body: FutureBuilder(
        future: DatabaseHelper.instance.database.then((db) async {
          final pedidos = await db.query('pedidos', orderBy: 'id DESC');
          final clientes = await db.query('clientes');
          final productos = await db.query('productos');
          return {
            'pedidos': pedidos,
            'clientes': clientes,
            'productos': productos,
          };
        }),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          
          final Map rawData = snapshot.data as Map;
          final List> pedidos = List>.from(rawData['pedidos'] ?? []);
          final List> clientes = List>.from(rawData['clientes'] ?? []);
          final List> productos = List>.from(rawData['productos'] ?? []);

          Map<String, String> codigosClientMap = {};
          for (var c in clientes) {
            codigosClientMap[c['nombre'].toString().trim()] = c['codigo'].toString().trim();
          }
          Map<String, String> codigosProdMap = {};
          for (var p in productos) {
            codigosProdMap[p['nombre'].toString().trim()] = p['codigo'].toString().trim();
          }
          if (pedidos.isEmpty) return const Center(child: Text('No hay pedidos registrados.'));
          
          bool todosSeleccionados = pedidos.isNotEmpty && pedidos.every((p) => pedidosSeleccionadosIds.contains(p['id']));

          return Column(
            children: [
              // 2. Cabecera con la opción de Seleccionar / Deseleccionar todos
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Total pedidos: ${pedidos.length} (Sel: ${pedidosSeleccionadosIds.length})',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          if (todosSeleccionados) {
                            pedidosSeleccionadosIds.clear();
                          } else {
                            pedidosSeleccionadosIds.clear();
                            for (var p in pedidos) {
                              pedidosSeleccionadosIds.add(p['id'] as int);
                            }
                          }
                        });
                      },
                      icon: Icon(todosSeleccionados ? Icons.deselect : Icons.select_all, size: 18),
                      label: Text(todosSeleccionados ? 'Deseleccionar todos' : 'Seleccionar todos'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: pedidos.length,
                  itemBuilder: (context, index) {
                    final p = pedidos[index];
                    int pId = p['id'] as int;
                    bool seleccionado = pedidosSeleccionadosIds.contains(pId);
                    String prodString = p['productos_json']?.toString() ?? '';
                    List<String> itemsList = prodString.split(';');
                    String semanaActual = p['semana']?.toString() ?? 'Sin Asignar';
                    
                    String nombreCliente = p['cliente'].toString().trim();
                    String codigoCliente = codigosClientMap[nombreCliente] ?? 'S/C';
                    return Card(
                      color: seleccionado ? Colors.indigo.shade50 : Colors.white,
                      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Checkbox(
                                  value: seleccionado,
                                  onChanged: (val) {
                                    setState(() {
                                      if (val == true) {
                                        pedidosSeleccionadosIds.add(pId);
                                      } else {
                                        pedidosSeleccionadosIds.remove(pId);
                                      }
                                    });
                                  },
                                ),
                                Expanded(
                                  child: Text(
                                    '${p['numero_pedido']} - [$codigoCliente] $nombreCliente [$semanaActual]', 
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.indigo),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.share, color: Colors.green, size: 20),
                                  onPressed: () => _enviarWhatsApp(nombreCliente, prodString, (p['total'] as num).toDouble()),
                                  constraints: const BoxConstraints(),
                                  padding: EdgeInsets.zero,
                                ),
                              ],
                            ),
                            const Divider(height: 12),
                            const Text('Productos:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
                            const SizedBox(height: 4),
                            ...itemsList.map((itemStr) {
                              if (itemStr.trim().isEmpty) return const SizedBox.shrink();
                              String texto = itemStr.trim();
                              int cant = 1;
                              if (texto.contains('(x')) {
                                var splitCant = texto.split('(x');
                                texto = splitCant[0].trim();
                                try {
                                  cant = int.parse(splitCant[1].replaceAll(')', '').trim());
                                } catch (_) {}
                              }
                              String nombreProd = texto;
                              String detalleProd = '';
                              if (texto.contains('[') && texto.endsWith(']')) {
                                int startIdx = texto.lastIndexOf('[');
                                nombreProd = texto.substring(0, startIdx).trim();
                                detalleProd = texto.substring(startIdx + 1, texto.length - 1).trim();
                              }
                              String codigoProd = codigosProdMap[nombreProd] ?? 'S/C';
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 6.0, left: 8.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '• [$codigoProd] $nombreProd (x$cant)', 
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                                    ),
                                    if (detalleProd.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(left: 16.0, top: 1.0),
                                        child: Text(
                                          detalleProd, 
                                          style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 11, color: Colors.grey),
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            }),
                            const Divider(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Total: L ${(p['total'] as num).toStringAsFixed(2)}', 
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.green),
                                ),
                                Text(
                                  'Fecha: ${p['fecha']}', 
                                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                                ),
                              ],
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () => _mostrarMenuOpciones(p),
                                icon: const Icon(Icons.more_vert, size: 16),
                                label: const Text('Opciones', style: TextStyle(fontSize: 12)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
