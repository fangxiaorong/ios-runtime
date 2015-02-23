//
// Created by Yavor Ivanov on 12/1/14.
// Copyright (c) 2014 Telerik. All rights reserved.
//

#include "ModuleObject.h"
#include <string>
#include <JavaScriptCore/FunctionConstructor.h>
#include <JavaScriptCore/JSGlobalObjectInspectorController.h>
#include <JavaScriptCore/Microtask.h>
#include <JavaScriptCore/Completion.h>
#include "ObjCProtocolWrapper.h"
#include "ObjCConstructorNative.h"
#include "Metadata.h"
#include "SymbolLoader.h"
#include "FFIFunctionCall.h"
#include "RecordConstructor.h"
#include "TypeFactory.h"

namespace NativeScript {
using namespace JSC;
using namespace Metadata;

const unsigned ModuleObject::StructureFlags = OverridesGetOwnPropertySlot | Base::StructureFlags;

const ClassInfo ModuleObject::s_info = { "ModuleObject", &Base::s_info, 0, 0, CREATE_METHOD_TABLE(ModuleObject) };

void ModuleObject::finishCreation(VM &vm, const WTF::String &name) {
    Base::finishCreation(vm);
    this->_name = name;
}

WTF::String ModuleObject::className(const JSObject *object) {
    const ModuleObject* moduleObject = jsCast<const ModuleObject*>(object);
    return moduleObject->_name + WTF::ASCIILiteral("Module");
}

bool ModuleObject::getOwnPropertySlot(JSObject* object, ExecState* execState, PropertyName propertyName, PropertySlot& propertySlot) {
    if (Base::getOwnPropertySlot(object, execState, propertyName, propertySlot)) {
        return true;
    }

    ModuleObject* moduleObject = jsCast<ModuleObject*>(object);
    GlobalObject* globalObject = jsCast<GlobalObject*>(execState->lexicalGlobalObject());
    VM& vm = execState->vm();

//    if (propertyName == globalObject->_interopIdentifier) {
//        propertySlot.setValue(object, DontEnum | ReadOnly | DontDelete, globalObject->interop());
//        return true;
//    }

    StringImpl* symbolName = propertyName.publicName();
    const Meta* symbolMeta = getMetadata()->findMeta(symbolName);
    if (!symbolMeta)
        return false;

    JSValue symbolWrapper;

    switch (symbolMeta->type()) {
        case Interface: {
            Class klass = objc_getClass(symbolMeta->name());
            if (!klass) {
                SymbolLoader::instance().ensureFramework(symbolMeta->framework());
                klass = objc_getClass(symbolMeta->name());
            }

            if (klass) {
                symbolWrapper = globalObject->typeFactory()->getObjCNativeConstructor(globalObject, symbolMeta->jsName());
                moduleObject->_objCConstructors.insert(std::pair<Class, Strong<ObjCConstructorBase>>(klass, Strong<ObjCConstructorBase>(vm, jsCast<ObjCConstructorBase*>(symbolWrapper))));
            }
            break;
        }
        case ProtocolType: {
            Protocol* aProtocol = objc_getProtocol(symbolMeta->name());
            if (!aProtocol) {
                SymbolLoader::instance().ensureFramework(symbolMeta->framework());
                aProtocol = objc_getProtocol(symbolMeta->name());
            }

            symbolWrapper = ObjCProtocolWrapper::create(vm, ObjCProtocolWrapper::createStructure(vm, globalObject, globalObject->objectPrototype()), static_cast<const ProtocolMeta*>(symbolMeta), aProtocol);
            if (aProtocol) {
                auto pair = std::pair<const Protocol*, Strong<ObjCProtocolWrapper>>(aProtocol, Strong<ObjCProtocolWrapper>(vm, jsCast<ObjCProtocolWrapper*>(symbolWrapper)));
                moduleObject->_objCProtocolWrappers.insert(pair);
            }
            break;
        }
        case Union: {
            //        symbolWrapper = globalObject->typeFactory()->createOrGetUnionConstructor(globalObject, symbolName);
            break;
        }
        case Struct: {
            symbolWrapper = globalObject->typeFactory()->getStructConstructor(globalObject, symbolName);
            break;
        }
        case MetaType::Function: {
            void* functionSymbol = SymbolLoader::instance().loadFunctionSymbol(symbolMeta->framework(), symbolMeta->name());
            if (functionSymbol) {
                const FunctionMeta* functionMeta = static_cast<const FunctionMeta*>(symbolMeta);
                Metadata::MetaFileOffset cursor = functionMeta->encodingOffset();
                JSCell* returnType = globalObject->typeFactory()->parseType(globalObject, cursor);
                const WTF::Vector<JSCell*> parametersTypes = globalObject->typeFactory()->parseTypes(globalObject, cursor, functionMeta->encodingCount() - 1);
                symbolWrapper = FFIFunctionCall::create(vm, globalObject->ffiFunctionCallStructure(), functionSymbol, functionMeta->jsName(), returnType, parametersTypes, functionMeta->ownsReturnedCocoaObject());
            }
            break;
        }
        case Var: {
            const VarMeta* varMeta = static_cast<const VarMeta*>(symbolMeta);
            void* varSymbol = SymbolLoader::instance().loadDataSymbol(varMeta->framework(), varMeta->name());
            if (varSymbol) {
                MetaFileOffset cursor = varMeta->encodingOffset();
                JSCell* symbolType = globalObject->typeFactory()->parseType(globalObject, cursor);
                symbolWrapper = getFFITypeMethodTable(symbolType).read(execState, varSymbol, symbolType);
            }
            break;
        }
        case JsCode: {
            WTF::String source = WTF::String(static_cast<const JsCodeMeta*>(symbolMeta)->jsCode());
            symbolWrapper = evaluate(execState, makeSource(source));
            break;
        }
        default: {
            break;
        }
    }

    if (symbolWrapper) {
        object->putDirectWithoutTransition(vm, propertyName, symbolWrapper);
        propertySlot.setValue(object, None, symbolWrapper);
        return true;
    }

    return false;
}

void ModuleObject::getOwnPropertyNames(JSObject* object, ExecState* execState, PropertyNameArray& propertyNames, EnumerationMode enumerationMode) {
    MetaFileReader* metadata = getMetadata();
    for (MetaIterator it = metadata->begin(); it != metadata->end(); ++it) {
        propertyNames.add(Identifier(execState, (*it)->jsName()));
    }

    Base::getOwnPropertyNames(object, execState, propertyNames, enumerationMode);
}

ObjCConstructorBase* ModuleObject::constructorFor(Class klass, Class fallback) {
    ASSERT(klass);

    auto kvp = this->_objCConstructors.find(klass);
    if (kvp != this->_objCConstructors.end()) {
        return kvp->second.get();
    }

    const Meta* meta = getMetadata()->findMeta(class_getName(klass));
    while (!meta) {
        klass = class_getSuperclass(klass);
        meta = getMetadata()->findMeta(class_getName(klass));
    }

    if (klass == [NSObject class] && fallback) {
        return constructorFor(fallback);
    }

    kvp = this->_objCConstructors.find(klass);
    if (kvp != this->_objCConstructors.end()) {
        return kvp->second.get();
    }

    GlobalObject* globalObject = jsCast<GlobalObject*>(this->globalObject());
    ObjCConstructorNative* constructor = globalObject->typeFactory()->getObjCNativeConstructor(globalObject, meta->jsName());
    this->_objCConstructors.insert(std::pair<Class, Strong<ObjCConstructorBase>>(klass, Strong<ObjCConstructorBase>(globalObject->vm(), constructor)));
    this->putDirectWithoutTransition(globalObject->vm(), Identifier(globalObject->globalExec(), class_getName(klass)), constructor);
    return constructor;
}

ObjCProtocolWrapper* ModuleObject::protocolWrapperFor(Protocol* aProtocol) {
    ASSERT(aProtocol);

    auto kvp = this->_objCProtocolWrappers.find(aProtocol);
    if (kvp != this->_objCProtocolWrappers.end()) {
        return kvp->second.get();
    }

    CString protocolName = protocol_getName(aProtocol);
    const Meta* meta = getMetadata()->findMeta(protocolName.data());
    if (meta && meta->type() != MetaType::ProtocolType) {
        protocolName = WTF::String::format("%sProtocol", protocolName.data()).utf8();
        meta = getMetadata()->findMeta(protocolName.data());
    }

    GlobalObject* globalObject = jsCast<GlobalObject*>(this->globalObject());
    ObjCProtocolWrapper* protocolWrapper = ObjCProtocolWrapper::create(globalObject->vm(), ObjCProtocolWrapper::createStructure(globalObject->vm(), globalObject, globalObject->objectPrototype()), static_cast<const ProtocolMeta*>(meta), aProtocol);
    this->_objCProtocolWrappers.insert(std::pair<const Protocol*, Strong<ObjCProtocolWrapper>>(aProtocol, Strong<ObjCProtocolWrapper>(globalObject->vm(), protocolWrapper)));
    this->putDirectWithoutTransition(globalObject->vm(), Identifier(globalObject->globalExec(), protocolName.data()), protocolWrapper, DontDelete | ReadOnly);

    return protocolWrapper;
}
}