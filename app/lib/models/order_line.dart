class OrderLine {
  final String designId;
  final int quantity;

  const OrderLine({required this.designId, required this.quantity});

  OrderLine copyWith({String? designId, int? quantity}) =>
      OrderLine(designId: designId ?? this.designId, quantity: quantity ?? this.quantity);

  @override
  String toString() => 'OrderLine($designId x$quantity)';
}
