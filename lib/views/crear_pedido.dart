import 'dart:convert';
import 'package:flutter/material.dart';
import '../database_helper.dart';

class CrearPedido extends StatefulWidget {
  final Map<String, dynamic>? pedidoAEditar; // Parámetro para saber si estamos editando
  final Function? onPedidoGuardado; // Callback para actualizar el historial automáticamente

  const CrearPedido({Key? key, this.pedidoAEditar, this.onPedidoGuardado}) : super(key: key);

  @override
  State<CrearPedido> createState() => _CrearPedidoState();
}

class _CrearPedidoState extends State<CrearPedido> {
  String? clienteSeleccionado;
  List<Map<String, dynamic>> productosPedido = [];
  List<Map<String, dynamic>> clientesDisponibles = [];
  List<Map<String, dynamic>> productosDisponibles = [];
  int? pedidoIdEditando;

  @override
  void initState() {
    super.initState();
    _cargarDatosLocales();

    // Si nos pasaron un pedido para editar, cargamos sus datos en pantalla
    if (widget.pedidoAEditar != null) {
      pedidoIdEditando = widget.pedidoAEditar!['id'];
      clienteSeleccionado = widget.pedidoAEditar!['cliente'];
      
      try {
        String productosJson = widget.pedidoAEditar!['productos_json'] ?? '[]';
        List decoded = jsonDecode(productosJson);
        productosPedido = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      } catch (e) {
        productosPedido = [];
      }
    }
  }

  Future<void> _cargarDatosLocales() async {
    final db = await DatabaseHelper.instance.database;
    final clientes = await db.query('clientes');
    final productos = await db.query('productos');

    setState(() {
      clientesDisponibles = clientes;
      productosDisponibles = productos;
    });
  }

  // --- DIÁLOGO CON TECLADO NUMÉRICO PARA LA CANTIDAD ---
  void _mostrarDialogoCantidad(BuildContext context, Map<String, dynamic> producto, int index) {
    final TextEditingController cantidadController = TextEditingController(
      text: producto['cantidad'].toString(),
    );

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('${producto['nombre']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Ingrese la cantidad deseada:'),
              const SizedBox(height: 12),
              TextField(
                controller: cantidadController,
                keyboardType: TextInputType.number, // <--- Teclado numérico directo
                autofocus: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Cantidad',
                ),
              ),
            ],
          ),
          actions: [
            // Botón Eliminar del pedido
            TextButton.icon(
              onPressed: () {
                setState(() {
                  productosPedido.removeAt(index);
                });
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.delete, color: Colors.red),
              label: const Text('Eliminar', style: TextStyle(color: Colors.red)),
            ),
            // Botón Cancelar
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancelar'),
            ),
            // Botón Guardar
            ElevatedButton(
              onPressed: () {
                int nuevaCantidad = int.tryParse(cantidadController.text) ?? 1;
                if (nuevaCantidad > 0) {
                  setState(() {
                    producto['cantidad'] = nuevaCantidad;
                    producto['valorTotal'] = nuevaCantidad * (producto['precio'] ?? 0.0);
                  });
                }
                Navigator.of(context).pop();
              },
              child: const Text('Guardar'),
            ),
          ],
        );
      },
    );
  }

  double get totalPedido {
    return productosPedido.fold(0.0, (sum, item) => sum + (item['valorTotal'] ?? 0.0));
  }

  void _guardarPedido() async {
    if (clienteSeleccionado == null || productosPedido.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seleccione un cliente y al menos un producto.')),
      );
      return;
    }

    final db = await DatabaseHelper.instance.database;
    final productosJson = jsonEncode(productosPedido);
    final fechaActual = DateTime.now().toIso8601String();

    if (pedidoIdEditando != null) {
      // Actualizar pedido existente
      await db.update(
        'pedidos',
        {
          'cliente': clienteSeleccionado,
          'productos_json': productosJson,
          'total': totalPedido,
          'total_real': totalPedido,
        },
        where: 'id = ?',
        whereArgs: [pedidoIdEditando],
      );
    } else {
      // Crear nuevo pedido
      await db.insert('pedidos', {
        'numero_pedido': 'PED-${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}',
        'cliente': clienteSeleccionado,
        'productos_json': productosJson,
        'total': totalPedido,
        'fecha': fechaActual,
        'semana': 'Semana 1',
        'gestionado': 0,
        'incidencia': '',
        'total_real': totalPedido,
      });
    }

    // Notificar para actualizar el historial automáticamente
    if (widget.onPedidoGuardado != null) {
      widget.onPedidoGuardado!();
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('¡Pedido guardado con éxito!')),
    );

    // Limpiar formulario o regresar
    setState(() {
      clienteSeleccionado = null;
      productosPedido.clear();
      pedidoIdEditando = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(pedidoIdEditando != null ? 'Editar Pedido' : 'Crear Pedido'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _guardarPedido,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Selector de Cliente
            DropdownButtonFormField<String>(
              value: clienteSeleccionado,
              hint: const Text('Seleccionar Cliente'),
              isExpanded: true,
              items: clientesDisponibles.map((cliente) {
                return DropdownMenuItem<String>(
                  value: cliente['nombre'].toString(),
                  child: Text('${cliente['codigo']} - ${cliente['nombre']}'),
                );
              }).toList(),
              onChanged: (value) {
                setState(() {
                  clienteSeleccionado = value;
                });
              },
            ),
            const SizedBox(height: 12),

            // Selector para agregar productos
            DropdownButtonFormField<Map<String, dynamic>>(
              hint: const Text('Agregar Producto'),
              isExpanded: true,
              items: productosDisponibles.map((prod) {
                return DropdownMenuItem<Map<String, dynamic>>(
                  value: prod,
                  child: Text('${prod['nombre']} (L ${prod['precio']})'),
                );
              }).toList(),
              onChanged: (prodSeleccionado) {
                if (prodSeleccionado != null) {
                  setState(() {
                    // Verificar si ya está agregado
                    var existente = productosPedido.firstWhere(
                      (p) => p['codigo'] == prodSeleccionado['codigo'],
                      orElse: () => {},
                    );

                    if (existente.isNotEmpty) {
                      existente['cantidad'] += 1;
                      existente['valorTotal'] = existente['cantidad'] * (existente['precio'] ?? 0.0);
                    } else {
                      productosPedido.add({
                        'codigo': prodSeleccionado['codigo'],
                        'nombre': prodSeleccionado['nombre'],
                        'precio': prodSeleccionado['precio'],
                        'cantidad': 1,
                        'unidades': 1,
                        'valorTotal': prodSeleccionado['precio'],
                      });
                    }
                  });
                }
              },
            ),
            const SizedBox(height: 20),

            // Lista de productos en el pedido
            Expanded(
              child: ListView.builder(
                itemCount: productosPedido.length,
                itemBuilder: (context, index) {
                  final prod = productosPedido[index];
                  return Card(
                    child: ListTile(
                      title: Text(prod['nombre'] ?? ''),
                      subtitle: Text('Cant: ${prod['cantidad']} x L ${prod['precio']}'),
                      trailing: Text('L ${prod['valorTotal'].toStringAsFixed(2)}'),
                      onTap: () => _mostrarDialogoCantidad(context, prod, index),
                    ),
                  );
                },
              ),
            ),

            // Total y botón de guardar
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.indigo.shade50.withOpacity(0.5),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Total del Pedido:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  Text('L ${totalPedido.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
