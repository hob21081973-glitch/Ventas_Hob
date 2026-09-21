import 'package:app_ventas_export_pdf/pdf_helper.dart';

class ReportesScreen extends StatefulWidget {
  const ReportesScreen({Key? key}) : super(key: key);

  @override
  _ReportesScreenState createState() => _ReportesScreenState();
}

class _ReportesScreenState extends State<ReportesScreen> {
  // Controladores para capturar los números de los selectores de pedidos
  final TextEditingController _controllerPedidoInicial = TextEditingController();
  final TextEditingController _controllerPedidoFinal = TextEditingController();
  bool _estaGenerando = false;

  @override
  void dispose() {
    _controllerPedidoInicial.dispose();
    _controllerPedidoFinal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Generar Reportes de Pedidos'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Seleccione el rango de pedidos a exportar:',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // Selector de Pedido Inicial
            TextField(
              controller: _controllerPedidoInicial,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Número de Pedido Inicial',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.filter_1),
              ),
            ),
            const SizedBox(height: 16),

            // Selector de Pedido Final
            TextField(
              controller: _controllerPedidoFinal,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Número de Pedido Final',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.filter_9_plus),
              ),
            ),
            const SizedBox(height: 24),

            // Botón para exportar
            ElevatedButton.icon(
              onPressed: _estaGenerando ? null : _exportarReportePDF,
              icon: _estaGenerando 
                ? const SizedBox(
                    width: 20, 
                    height: 20, 
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)
                  )
                : const Icon(Icons.picture_as_pdf),
              label: Text(_estaGenerando ? 'Generando PDF...' : 'Exportar Reporte a PDF'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Lógica que se ejecuta al presionar el botón
  Future<void> _exportarReportePDF() async {
    // Validar que los campos no estén vacíos
    if (_controllerPedidoInicial.text.isEmpty || _controllerPedidoFinal.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Por favor, ingresa el pedido inicial y final.')),
      );
      return;
    }

    setState(() {
      _estaGenerando = true;
    });

    try {
      int pedidoIni = int.tryParse(_controllerPedidoInicial.text) ?? 1;
      int pedidoFin = int.tryParse(_controllerPedidoFinal.text) ?? 1;

      // Aquí puedes conectar luego tu consulta real a la base de datos de la app.
      // Esta lista de ejemplo ya incluye productos que se ordenarán automáticamente de mayor a menor.
      List<Map<String, dynamic>> productosVendidosEjemplo = [
        {'nombre': 'Camisa Térmica', 'cantidad': 4, 'valorTotal': 120.0},
        {'nombre': 'Pantalón Jeans', 'cantidad': 2, 'valorTotal': 250.0},
        {'nombre': 'Zapatillas Urbanas', 'cantidad': 1, 'valorTotal': 300.0},
      ];

      // Llamada al helper que creamos antes para armar el PDF y guardarlo en Descargas
      String? rutaGuardada = await PdfHelper.generarYGuardarReporteGeneral(
        pedidoInicial: pedidoIni,
        pedidoFinal: pedidoFin,
        listaProductosVendidos: productosVendidosEjemplo,
        nombreArchivo: 'Reporte_Pedidos_${pedidoIni}_al_$pedidoFin.pdf',
      );

      if (!mounted) return;

      if (rutaGuardada != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('¡Reporte guardado con éxito en Descargas!'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo guardar el reporte. Revisa los permisos.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ocurrió un error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) {
        setState(() {
          _estaGenerando = false;
        });
      }
    }
  }
}
