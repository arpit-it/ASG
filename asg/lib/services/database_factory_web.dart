import 'package:sembast_web/sembast_web.dart';

Future<Database> openStudioDatabase() =>
    databaseFactoryWeb.openDatabase('asg-studio-v2', mode: DatabaseMode.create);
