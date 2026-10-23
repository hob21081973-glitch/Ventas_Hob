import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:sqflite/sqflite.dart';
import 'package:intl/intl.dart';

class VistaResumenPedidos extends StatefulWidget {
  const VistaResumenPedidos({Key? key}) : super(key: key);

  @override
  _VistaResumenPedidosState createState() => _VistaResumenPedidosState();
}

class _VistaResumenPedidosState extends State<VistaResumenPedidos> {
  bool _cargando = true;

  // Manejo de Semanas
  List<String> _semanasDisponibles = ['Seleccione Semana'];
  String _semanaSeleccionada = 'Seleccione Semana';

  // Manejo de Pedidos
  List<Map<String, dynamic>> _pedidosSemana = [];
  Map<String, dynamic>? _pedidoSeleccionado;

  // Controladores para campos editables
  final TextEditingController _entregadoController = TextEditingController();
  final TextEditingController _comentarioController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargarSemanas();
  }

  Future<Database> _obtenerBaseDatos() async {
    final path = await getDatabasesPath();
    final dbPath = '$path/app_ventas.db';
    return openDatabase(dbPath);
  }

  // Asegura que existan las columnas de entrega en SQLite sin borrar datos
  Future<void> _verificarEstructuraBD(Database db) async {
    try {
      await db.execute("ALTER TABLE pedidos ADD COLUMN valor_entregado REAL DEFAULT 0");
    } catch (_) {}
    try {
      await db.execute("ALTER TABLE pedidos ADD COLUMN comentario_incidencia TEXT DEFAULT ''");
    } catch (_) {}
  }

  Future<void> _cargarSemanas() async {
    setState(() => _cargando = true);
    try {
      final db = await _obtenerBaseDatos();
      await _verificarEstructuraBD(db);

      final pragma = await db.rawQuery("PRAGMA table_info(pedidos)");
      List<String> columnas = pragma.map((c) => c['name'].toString()).toList();

      Set<String> semanas = {};

      String? colSemana = columnas.firstWhere(
        (c) => c.toLowerCase().contains('semana') || c.toLowerCase().contains('grupo'),
        orElse: () => '',
      );

      if (colSemana.isNotEmpty) {
        final List<Map<String, dynamic>> res = await db.rawQuery(
          "SELECT DISTINCT $colSemana FROM pedidos WHERE $colSemana IS NOT NULL AND $colSemana != ''"
        );
        for (var fila in res) {
          semanas.add(fila[colSemana].toString().trim());
        }
      }

      List<String> listaFinal = ['Seleccione Semana', ...semanas.toList()..sort()];

      setState(() {
        _semanasDisponibles = listaFinal;
        _cargando = false;
      });
    } catch (e) {
      debugPrint("Error al cargar semanas: $e");
      setState(() => _cargando = false);
    }
  }

  Future<void> _cargarPedidosPorSemana(String semana) async {
    if (semana == 'Seleccione Semana') {
      setState(() {
        _pedidosSemana = [];
        _pedidoSeleccionado = null;
        _limpiarCampos();
      });
      return;
    }

    setState(() => _cargando = true);
    try {
      final db = await _obtenerBaseDatos();
      final pragma = await db.rawQuery("PRAGMA table_info(pedidos)");
      List<String> columnas = pragma.map((c) => c['name'].toString()).toList();

      String? colSemana = columnas.firstWhere(
        (c) => c.toLowerCase().contains('semana') || c.toLowerCase().contains('grupo'),
        orElse: () => '',
      );

      List<Map<String, dynamic>> resultados = [];
      if (colSemana.isNotEmpty) {
        resultados = await db.query(
          'pedidos',
          where: '$colSemana = ?',
          whereArgs: [semana],
        );
      }

      setState(() {
        _pedidosSemana = resultados;
        _pedidoSeleccionado = null;
        _limpiarCampos();
        _cargando = false;
      });
    } catch (e) {
      debugPrint("Error al cargar pedidos: $e");
      setState(() => _cargando = false);
    }
  }

  void _seleccionarPedido(Map<String, dynamic>? pedido) {
    if (pedido == null) {
      _limpiarCampos();
      return;
    }

    double facturado = double.tryParse(pedido['total']?.toString() ?? pedido['monto_total']?.toString() ?? '0') ?? 0.0;
    double entregado = double.tryParse(pedido['valor_entregado']?.toString() ?? '0') ?? facturado;

    setState(() {
      _pedidoSeleccionado = pedido;
      _entregadoController.text = entregado.toStringAsFixed(2);
      _comentarioController.text = pedido['comentario_incidencia']?.toString() ?? 'Entrega Completa';
    });
  }

  void _limpiarCampos() {
    _entregadoController.clear();
    _comentarioController.clear();
  }

  Future<void> _guardarCambiosPedido() async {
    if (_pedidoSeleccionado == null) return;

    final idPedido = _pedidoSeleccionado!['id'];
    final double valorEntregado = double.tryParse(_entregadoController.text) ?? 0.0;
    final String comentario = _comentarioController.text.trim();

    try {
      final db = await _obtenerBaseDatos();
      await db.update(
        'pedidos',
        {
          'valor_entregado': valorEntregado,
          'comentario_incidencia': comentario,
        },
        where: 'id = ?',
        whereArgs: [idPedido],
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pedido actualizado correctamente'), backgroundColor: Colors.green),
      );

      // Recargar la lista manteniendo la semana seleccionada
      await _cargarPedidosPorSemana(_semanaSeleccionada);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al guardar cambios: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _generarPdfReporteEntregas() async {
    if (_pedidosSemana.isEmpty) return;

    final pdf = pw.Document();
    final formatoMoneda = NumberFormat.currency(symbol: 'L ', decimalDigits: 2);
    final fechaHoy = DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now());

    double totalFacturadoSemana = 0.0;
    double totalEntregadoSemana = 0.0;

    for (var p in _pedidosSemana) {
      totalFacturadoSemana += double.tryParse(p['total']?.toString() ?? p['monto_total']?.toString() ?? '0') ?? 0.0;
      totalEntregadoSemana += double.tryParse(p['valor_entregado']?.toString() ?? '0') ?? 0.0;
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Reporte de Entregas - $_semanaSeleccionada',
                      style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
                  pw.Text(fechaHoy, style: const pw.TextStyle(fontSize: 9)),
                ],
              ),
            ),
            pw.SizedBox(height: 10),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
              children: [
                pw.Text('Total Facturado: ${formatoMoneda.format(totalFacturadoSemana)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                pw.Text('Total Entregado: ${formatoMoneda.format(totalEntregadoSemana)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                pw.Text('Diferencia: ${formatoMoneda.format(totalFacturadoSemana - totalEntregadoSemana)}', style: pw.TextStyle(color: PdfColors.red900)),
              ],
            ),
            pw.SizedBox(height: 15),
            pw.Table.fromTextArray(
              headers: ['Código/Cliente', 'Facturado', 'Entregado', 'Comentario / Incidencia'],
              data: _pedidosSemana.map((p) {
                final cod = p['codigo_cliente']?.toString() ?? p['id']?.toString() ?? '';
                final cliente = p['nombre_cliente']?.toString() ?? p['cliente']?.toString() ?? 'Cliente';
                final fact = double.tryParse(p['total']?.toString() ?? p['monto_total']?.toString() ?? '0') ?? 0.0;
                final ent = double.tryParse(p['valor_entregado']?.toString() ?? '0') ?? 0.0;
                final inc = p['comentario_incidencia']?.toString() ?? 'Completo';

                return ['$cod - $cliente', formatoMoneda.format(fact), formatoMoneda.format(ent), inc];
              }).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
            ),
          ];
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
      name: 'Reporte_Entregas_${_semanaSeleccionada.replaceAll(' ', '_')}.pdf',
    );
  }

  @override
  Widget build(BuildContext context) {
    final formatoMoneda = NumberFormat.currency(symbol: 'L ', decimalDigits: 2);

    final String clienteCodNombre = _pedidoSeleccionado != null
        ? "${_pedidoSeleccionado!['codigo_cliente'] ?? _pedidoSeleccionado!['id'] ?? ''} - ${_pedidoSeleccionado!['nombre_cliente'] ?? _pedidoSeleccionado!['cliente'] ?? 'Cliente'}"
        : "";

    final double valorFacturado = _pedidoSeleccionado != null
        ? double.tryParse(_pedidoSeleccionado!['total']?.toString() ?? _pedidoSeleccionado!['monto_total']?.toString() ?? '0') ?? 0.0
        : 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Resumen por Pedido'),
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. Selector de Semana
                  Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.date_range, color: Colors.blue),
                          const SizedBox(width: 10),
                          const Text('Semana:', style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _semanaSeleccionada,
                                isExpanded: true,
                                items: _semanasDisponibles.map((s) {
                                  return DropdownMenuItem(value: s, child: Text(s));
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => _semanaSeleccionada = val);
                                    _cargarPedidosPorSemana(val);
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 8),

                  // 2. Selector de Pedido
                  Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.shopping_bag, color: Colors.orange),
                          const SizedBox(width: 10),
                          const Text('Pedido:', style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<Map<String, dynamic>>(
                                value: _pedidoSeleccionado,
                                hint: const Text('Seleccione un pedido'),
                                isExpanded: true,
                                items: _pedidosSemana.map((p) {
                                  final cod = p['codigo_cliente'] ?? p['id'] ?? '';
                                  final nom = p['nombre_cliente'] ?? p['cliente'] ?? 'Cliente';
                                  return DropdownMenuItem(
                                    value: p,
                                    child: Text('$cod - $nom', overflow: TextOverflow.ellipsis),
                                  );
                                }).toList(),
                                onChanged: (p) => _seleccionarPedido(p),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // 3. Formulario de Datos del Pedido
                  if (_pedidoSeleccionado != null) ...[
                    // Campo 1: Solo vista - Código y Nombre del Cliente
                    TextFormField(
                      initialValue: clienteCodNombre,
                      key: ValueKey('client_${_pedidoSeleccionado!['id']}'),
                      readOnly: true,
                      decoration: const InputDecoration(
                        labelText: '1. Código y Nombre del Cliente',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.person_outline),
                        filled: true,
                        fillColor: Color(0xFFF2F2F2),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Campo 2: Solo vista - Valor Total Facturado
                    TextFormField(
                      initialValue: formatoMoneda.format(valorFacturado),
                      key: ValueKey('total_${_pedidoSeleccionado!['id']}'),
                      readOnly: true,
                      decoration: const InputDecoration(
                        labelText: '2. Valor Total del Pedido (Facturado)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.attach_money),
                        filled: true,
                        fillColor: Color(0xFFF2F2F2),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Campo 3: Editable - Valor Total Entregado
                    TextFormField(
                      controller: _entregadoController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: '3. Valor Total Entregado',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.payments_outlined, color: Colors.green),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Campo 4: Editable - Comentario / Incidencia
                    TextFormField(
                      controller: _comentarioController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: '4. Comentario de Incidencia / Entrega',
                        hintText: 'Ej. Entrega Completa, Faltó 1 caja, etc.',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.comment_outlined),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Botón Guardar Cambios del Pedido
                    ElevatedButton.icon(
                      onPressed: _guardarCambiosPedido,
                      icon: const Icon(Icons.save),
                      label: const Text('Guardar Pedido', style: TextStyle(fontSize: 16)),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],

                  const SizedBox(height: 24),

                  // Botón Generar PDF Reporte Semanal
                  ElevatedButton.icon(
                    onPressed: (_semanaSeleccionada != 'Seleccione Semana' && _pedidosSemana.isNotEmpty)
                        ? _generarPdfReporteEntregas
                        : null,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('Generar PDF Reporte de Entregas', style: TextStyle(fontSize: 15)),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: Colors.red[700],
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
