import 'dart:convert';
import 'package:flutter/material.dart';
import '../database_helper.dart';

class CrearPedido extends StatefulWidget {
  final Map<String, dynamic>? pedidoAEditar;
  final Function? onPedidoGuardado;

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

  final TextEditingController _clienteController = TextEditingController();
  final TextEditingController _productoController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargarDatosLocales();

    if (widget.pedidoAEditar != null) {
      pedidoIdEditando = widget.pedidoAEditar!['id'];
      clienteSeleccionado = widget.pedidoAEditar!['cliente'];
      _clienteController.text = clienteSeleccionado ?? '';
      
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
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Cantidad',
                ),
              ),
            ],
          ),
          actions: [
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
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancelar'),
            ),
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
    if (clienteSeleccionado == null || clienteSeleccionado!.isEmpty || productosPedido.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seleccione un cliente y al menos un producto.')),
      );
      return;
    }

    final db = await DatabaseHelper.instance.database;
    final productosJson = jsonEncode(productosPedido);
    final fechaActual = DateTime.now().toIso8601String();

    if (pedidoIdEditando != null) {
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

    if (widget.onPedidoGuardado != null) {
      widget.onPedidoGuardado!();
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('¡Pedido guardado con éxito!')),
    );

    setState(() {
      clienteSeleccionado = null;
      _clienteController.clear();
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
            // Autocomplete para Buscar Cliente
            Autocomplete<Map<String, dynamic>>(
              optionsBuilder: (TextEditingValue textEditingValue) {
                if (textEditingValue.text == '') {
                  return clientesDisponibles;
                }
                return clientesDisponibles.where((cliente) {
                  final nombre = cliente['nombre'].toString().toLowerCase();
                  final codigo = cliente['codigo'].toString().toLowerCase();
                  final query = textEditingValue.text.toLowerCase();
                  return nombre.contains(query) || codigo.contains(query);
                });
              },
              displayStringForOption: (option) => '${option['codigo']} - ${option['nombre']}',
              onSelected: (selection) {
                setState(() {
                  clienteSeleccionado = selection['nombre'].toString();
                  _clienteController.text = '${selection['codigo']} - ${selection['nombre']}';
                });
              },
              fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                // Sincronizar el texto si ya venía precargado
                if (controller.text.isEmpty && _clienteController.text.isNotEmpty) {
                  controller.text = _clienteController.text;
                }
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  decoration: const InputDecoration(
                    labelText: 'Buscar Cliente',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.search),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),

            // Autocomplete para Buscar Producto
            Autocomplete<Map<String, dynamic>>(
              optionsBuilder: (TextEditingValue textEditingValue) {
                if (textEditingValue.text == '') {
                  return const Iterable<Map<String, dynamic>>.empty();
                }
                return productosDisponibles.where((prod) {
                  final nombre = prod['nombre'].toString().toLowerCase();
                  final query = textEditingValue.text.toLowerCase();
                  return nombre.contains(query);
                });
              },
              displayStringForOption: (option) => '${option['nombre']} (L ${option['precio']})',
              onSelected: (prodSeleccionado) {
                setState(() {
                  var existente = productosPedido.firstWhere(
                    (p) => p['codigo'] == prodSeleccionado['codigo'],
                    orElse: () => {},
                  );

                  if (existente.isNotEmpty) {
                    existente['cantidad'] += 1;
                    existente['valorTotal'] = existente['cantidad'] * (prodSeleccionado['precio'] ?? 0.0);
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
                  _productoController.clear();
                });
              },
              fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  decoration: const InputDecoration(
                    labelText: 'Agregar Producto',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.search),
                    suffixIcon: Icon(Icons.add),
                  ),
                );
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

            // Total del pedido
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
