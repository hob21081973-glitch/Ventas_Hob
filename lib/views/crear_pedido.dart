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

  @override
  void initState() {
    super.initState();
    _cargarDatosLocales();

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

  // --- MODAL DE BÚSQUEDA DE CLIENTES ---
  void _mostrarBuscadorClientes() {
    TextEditingController searchController = TextEditingController();
    List<Map<String, dynamic>> listaFiltrada = List.from(clientesDisponibles);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setStateModal) {
            return AlertDialog(
              title: const Text('Seleccionar Cliente'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: searchController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Buscar por nombre o código',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) {
                        setStateModal(() {
                          listaFiltrada = clientesDisponibles.where((cliente) {
                            final nombre = cliente['nombre'].toString().toLowerCase();
                            final codigo = cliente['codigo'].toString().toLowerCase();
                            final query = value.toLowerCase();
                            return nombre.contains(query) || codigo.contains(query);
                          }).toList();
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: listaFiltrada.length,
                        itemBuilder: (context, index) {
                          final cliente = listaFiltrada[index];
                          return ListTile(
                            title: Text('${cliente['codigo']} - ${cliente['nombre']}'),
                            subtitle: Text(cliente['direccion'] ?? ''),
                            onTap: () {
                              setState(() {
                                clienteSeleccionado = cliente['nombre'].toString();
                              });
                              Navigator.of(context).pop();
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancelar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // --- MODAL DE BÚSQUEDA DE PRODUCTOS ---
  void _mostrarBuscadorProductos() {
    TextEditingController searchController = TextEditingController();
    List<Map<String, dynamic>> listaFiltrada = List.from(productosDisponibles);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setStateModal) {
            return AlertDialog(
              title: const Text('Seleccionar Producto'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: searchController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Buscar producto',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) {
                        setStateModal(() {
                          listaFiltrada = productosDisponibles.where((prod) {
                            final nombre = prod['nombre'].toString().toLowerCase();
                            final query = value.toLowerCase();
                            return nombre.contains(query);
                          }).toList();
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: listaFiltrada.length,
                        itemBuilder: (context, index) {
                          final prod = listaFiltrada[index];
                          return ListTile(
                            title: Text(prod['nombre'] ?? ''),
                            trailing: Text('L ${prod['precio']}'),
                            onTap: () {
                              setState(() {
                                var existente = productosPedido.firstWhere(
                                  (p) => p['codigo'] == prod['codigo'],
                                  orElse: () => {},
                                );

                                if (existente.isNotEmpty) {
                                  existente['cantidad'] += 1;
                                  existente['valorTotal'] = existente['cantidad'] * (prod['precio'] ?? 0.0);
                                } else {
                                  productosPedido.add({
                                    'codigo': prod['codigo'],
                                    'nombre': prod['nombre'],
                                    'precio': prod['precio'],
                                    'cantidad': 1,
                                    'unidades': 1,
                                    'valorTotal': prod['precio'],
                                  });
                                }
                              });
                              Navigator.of(context).pop();
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancelar'),
                ),
              ],
            );
          },
        );
      },
    );
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
            // Botón / Caja para Seleccionar Cliente
            InkWell(
              onTap: _mostrarBuscadorClientes,
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Cliente',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person_search),
                ),
                child: Text(
                  clienteSeleccionado ?? 'Buscar Cliente',
                  style: TextStyle(
                    color: clienteSeleccionado == null ? Colors.grey[600] : Colors.black87,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Botón / Caja para Agregar Producto
            InkWell(
              onTap: _mostrarBuscadorProductos,
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Agregar Producto',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.add_shopping_cart),
                ),
                child: Text(
                  'Tocar para buscar y agregar producto',
                  style: TextStyle(color: Colors.grey[600], fontSize: 16),
                ),
              ),
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
