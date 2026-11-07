# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Portable defenses for the fixed real-runner dispatch adapter."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import f12_runner_adapters as adapters

class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.source=self.root/'source';self.source.mkdir()
        self.project=self.root/'project';self.project.mkdir()
        self.cache=self.project/'.dart_tool/hooks_runner';self.cache.mkdir(parents=True)
        self.packages=self.project/'.dart_tool/package_config.json';self.packages.write_text('{}')
        self.config={'source':str(self.source),'project':str(self.project),'cache':str(self.cache),'packages':str(self.packages)}
        self.out=self.cache/'fixture_b/1234567890/hook.dill';self.out.parent.mkdir(parents=True)
        self.script=self.source/'fixture_b/hook/build.dart';self.script.parent.mkdir(parents=True);self.script.write_text('fixed')
        self.compile=['compile','kernel','--packages='+str(self.packages),'--output='+str(self.out),'--depfile='+str(self.out)+'.d',str(self.script)]
    def test_real_compile_shape_is_admitted(self):
        result=adapters.admit(self.compile,self.config,str(self.project));self.assertEqual(result[:3],('compile',self.script,self.out))
    def test_command_expansion_and_context_fail_before_launch(self):
        cases=[self.compile+['--enable-asserts'],self.compile[1:],['run','untrusted.dart'],self.compile[:-1]+[str(self.source/'fixture_b/hook/other.dart')],self.compile[:3]+['--output=/tmp/escape.dill']+self.compile[4:]]
        for args in cases:
            with self.subTest(args=args),self.assertRaises(ValueError):adapters.admit(args,self.config,str(self.project))
        with self.assertRaises(ValueError):adapters.admit(self.compile,self.config,str(self.source))
    def test_kernel_and_depfile_cannot_cross_cache_directories(self):
        args=self.compile.copy();args[4]='--depfile='+str(self.cache/'other/file.d')
        with self.assertRaises(ValueError):adapters.admit(args,self.config,str(self.project))
    def test_compiler_cannot_write_another_package_cache(self):
        args=self.compile.copy();other=self.cache/'fixture_a/1234567890/hook.dill';args[3]='--output='+str(other);args[4]='--depfile='+str(other)+'.d'
        with self.assertRaises(ValueError):adapters.admit(args,self.config,str(self.project))
    def test_link_and_parent_traversal_refused(self):
        linked=self.root/'linked';linked.symlink_to(self.out.parent,target_is_directory=True)
        for path in [linked/'kernel.dill', self.cache/'../outside.dill', Path('/tmp/external.dill')]:
            with self.subTest(path=path),self.assertRaises(ValueError):adapters.beneath(path,self.cache)
    def test_hook_identity_and_working_directory_are_bound(self):
        input_path=self.out.parent/'input.json';value={'package_name':'fixture_b','package_root':str(self.source/'fixture_b')+'/'};input_path.write_text(json.dumps(value))
        args=['--packages='+str(self.packages),str(self.out),'--config='+str(input_path)]
        self.assertEqual(adapters.admit(args,self.config,str(self.source/'fixture_b'))[0],'hook')
        for key,bad in [('package_name','external'),('package_root','/tmp/other/')]:
            changed=dict(value);changed[key]=bad;input_path.write_text(json.dumps(changed))
            with self.assertRaises(ValueError):adapters.admit(args,self.config,str(self.source/'fixture_b'))
        input_path.write_text(json.dumps(value))
        with self.assertRaises(ValueError):adapters.admit(args,self.config,str(self.source/'fixture_a'))
    def test_duplicate_hook_input_fails(self):
        input_path=self.out.parent/'input.json';input_path.write_text('{"package_name":"fixture_b","package_name":"fixture_b"}')
        with self.assertRaises(ValueError):adapters.admit(['--packages='+str(self.packages),str(self.out),'--config='+str(input_path)],self.config,str(self.source/'fixture_b'))
    def test_invalid_dispatch_does_not_launch(self):
        self.config['transcript']=str(self.root/'transcript')
        with patch.object(adapters.subprocess,'Popen') as launch:
            self.assertEqual(adapters.dispatch(self.config,['run','untrusted']),2);launch.assert_not_called()
    def test_fixture_bytes_and_public_cli_are_fixed(self):
        fixture_root=Path(adapters.__file__).parent/'f12_adapter_fixtures'
        for name,digest in adapters.FIXTURES.items():self.assertEqual(hashlib.sha256((fixture_root/name).read_bytes()).hexdigest(),digest)
        source=Path(adapters.__file__).read_text();self.assertNotIn("add_argument('--candidate",source);self.assertNotIn("add_argument('--command",source)
    def test_compiler_dependency_identity_and_bounds(self):
        source=self.root/'trusted.dart';source.write_text('installed')
        depfile=self.root/'driver.d';depfile.write_text('/output: '+str(source))
        self.assertEqual(adapters.trusted_imports(depfile),{str(source):hashlib.sha256(b'installed').hexdigest()})
        source.write_text('changed');self.assertNotEqual(adapters.trusted_imports(depfile)[str(source)],hashlib.sha256(b'installed').hexdigest())
        depfile.write_text('/output: ')
        with self.assertRaises(ValueError):adapters.trusted_imports(depfile)

if __name__=='__main__':unittest.main()
