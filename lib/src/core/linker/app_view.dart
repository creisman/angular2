// @ignoreProblemForFile DEAD_CODE
import 'dart:async';
import 'dart:html';
import 'dart:js_util' as js_util;

import 'package:angular2/src/core/change_detection/change_detection.dart'
    show ChangeDetectorRef, ChangeDetectionStrategy, ChangeDetectorState;
import 'package:angular2/src/core/di.dart' show Injector;
import 'package:angular2/src/core/di/injector.dart' show THROW_IF_NOT_FOUND;
import 'package:angular2/src/core/metadata/view.dart' show ViewEncapsulation;
import 'package:angular2/src/core/render/api.dart';
import 'package:angular2/src/platform/dom/shared_styles_host.dart';

import 'package:meta/meta.dart';
import '../zone/ng_zone.dart';
import 'app_view_utils.dart';
import 'component_factory.dart';
import 'element_injector.dart' show ElementInjector;
import 'exceptions.dart' show ViewDestroyedException;
import 'template_ref.dart';
import 'view_container.dart';
import 'view_ref.dart' show ViewRefImpl;
import 'view_type.dart' show ViewType;

export 'package:angular2/src/core/change_detection/component_state.dart';

/// **INTERNAL ONLY**: Will be made private once the reflective compiler is out.
///
/// Template anchor `<!-- template bindings={}` for cloning.
@visibleForTesting
final ngAnchor = new Comment('template bindings={}');

/// ***INTERNAL ONLY**: Whether a crash was detected in change detection.
///
/// When non-null, change detection is re-run (synchronously), in a slow-mode
/// that individually checks components, and disables change detection for them
/// if there is a failure detected.
@visibleForTesting
AppView lastGuardedView;

/// Exception caught for [lastGuardedView].
@visibleForTesting
dynamic caughtException;

/// Stack trace caught for [lastGuardedView].
@visibleForTesting
dynamic caughtStack;

/// Set to `true` when Angular modified the DOM.
///
/// May be used in order to optimize polling techniques that attempt to only
/// process events after a significant change detection cycle (i.e. one that
/// modified the DOM versus a no-op).
bool domRootRendererIsDirty = false;

const _UndefinedInjectorResult = const Object();

/// Base class for a generated templates for a given [Component] type [T].
abstract class AppView<T> {
  /// The type of view (host element, complete template, embedded template).
  final ViewType type;

  /// Local values scoped to this view.
  final Map<String, dynamic> locals;

  /// Parent generated view.
  final AppView parentView;

  /// Index of this view within the [parentView].
  final int parentIndex;

  /// View reference interface (user-visible API).
  ViewRefImpl ref;

  /// A representation of how the component will be rendered in the DOM.
  ///
  /// This is _lazily_ set via [setupComponentType] in a generated constructor.
  RenderComponentType componentType;

  /// The root element.
  ///
  /// This is _lazily_ initialized in a generated constructor.
  HtmlElement rootEl;

  /// What type of change detection the view is using.
  ChangeDetectionStrategy _cdMode;

  // Improves change detection tree traversal by caching change detection mode
  // and change detection state checks. When set to true, this view doesn't need
  // to be change detected.
  bool _skipChangeDetection = false;

  /// Tracks the root DOM elements or view containers (for `<template>`).
  ///
  /// **INTERNAL ONLY**: Not part of the supported public API.
  @visibleForTesting
  List rootNodesOrViewContainers;

  final List<OnDestroyCallback> _onDestroyCallbacks = <OnDestroyCallback>[];
  List subscriptions;
  ViewContainer viewContainerElement;

  // The names of the below fields must be kept in sync with codegen_name_util.ts or
  // change detection will fail.
  ChangeDetectorState _cdState = ChangeDetectorState.NeverChecked;

  /// The context against which data-binding expressions in this view are
  /// evaluated against.
  ///
  /// This is always a component instance.
  T ctx;
  List<dynamic /* dynamic | List < dynamic > */ > projectableNodes;
  bool destroyed = false;
  Injector _hostInjector;

  AppView(
    this.type,
    this.locals,
    this.parentView,
    this.parentIndex,
    this._cdMode,
  ) {
    ref = new ViewRefImpl(this);
  }

  void setupComponentType(RenderComponentType renderType) {
    if (!renderType.stylesShimmed) {
      renderType.shimStyles(sharedStylesHost);
      renderType.stylesShimmed = true;
    }
    componentType = renderType;
  }

  /// Sets change detection mode for this view and caches flag to skip
  /// change detection if mode and state don't require one.
  ///
  /// Nodes don't require CD if they are Detached or already Checked or
  /// if error state has been set due a prior exception.
  ///
  /// Typically a view alternates between CheckOnce and Checked modes.
  set cdMode(ChangeDetectionStrategy value) {
    if (_cdMode != value) {
      _cdMode = value;
      _updateSkipChangeDetectionFlag();
    }
  }

  ChangeDetectionStrategy get cdMode => _cdMode;

  /// Sets change detection state and caches flag to skip change detection
  /// if mode and state don't require one.
  set cdState(ChangeDetectorState value) {
    if (_cdState != value) {
      _cdState = value;
      _updateSkipChangeDetectionFlag();
    }
  }

  ChangeDetectorState get cdState => _cdState;

  void _updateSkipChangeDetectionFlag() {
    _skipChangeDetection =
        identical(_cdMode, ChangeDetectionStrategy.Detached) ||
            identical(_cdMode, ChangeDetectionStrategy.Checked) ||
            identical(_cdState, ChangeDetectorState.Errored);
  }

  ComponentRef create(T context,
      List<dynamic /* dynamic | List < dynamic > */ > givenProjectableNodes) {
    ctx = context;
    projectableNodes = givenProjectableNodes;
    return build();
  }

  /// Builds host level view.
  ComponentRef createHostView(Injector hostInjector,
      List<dynamic /* dynamic | List < dynamic > */ > givenProjectableNodes) {
    _hostInjector = hostInjector;
    projectableNodes = givenProjectableNodes;
    return build();
  }

  /// Returns the ComponentRef for the host element for ViewType.HOST.
  ///
  /// Overwritten by implementations.
  ComponentRef build() => null;

  /// Called by build once all dom nodes are available.
  void init(List rootNodesOrViewContainers, List subscriptions) {
    this.rootNodesOrViewContainers = rootNodesOrViewContainers;
    this.subscriptions = subscriptions;
    if (type == ViewType.COMPONENT) {
      dirtyParentQueriesInternal();
    }
  }

  dynamic createElement(
      dynamic parent, String name, RenderDebugInfo debugInfo) {
    var nsAndName = splitNamespace(name);
    var el = nsAndName[0] != null
        ? document.createElementNS(NAMESPACE_URIS[nsAndName[0]], nsAndName[1])
        : document.createElement(nsAndName[1]);
    String contentAttr = componentType.contentAttr;
    if (contentAttr != null) {
      el.attributes[contentAttr] = '';
    }
    parent?.append(el);
    domRootRendererIsDirty = true;
    return el;
  }

  void attachViewAfter(dynamic node, List<Node> viewRootNodes) {
    moveNodesAfterSibling(node, viewRootNodes);
    domRootRendererIsDirty = true;
  }

  dynamic injectorGet(token, int nodeIndex,
      [notFoundValue = THROW_IF_NOT_FOUND]) {
    var result = _UndefinedInjectorResult;
    AppView view = this;
    while (identical(result, _UndefinedInjectorResult)) {
      if (nodeIndex != null) {
        result = view.injectorGetInternal(
            token, nodeIndex, _UndefinedInjectorResult);
      }
      if (identical(result, _UndefinedInjectorResult) &&
          view._hostInjector != null) {
        result = view._hostInjector.get(token, notFoundValue);
      }
      nodeIndex = view.parentIndex;
      view = view.parentView;
    }
    return result;
  }

  /// Overwritten by implementations
  dynamic injectorGetInternal(
      dynamic token, int nodeIndex, dynamic notFoundResult) {
    return notFoundResult;
  }

  Injector injector(int nodeIndex) => new ElementInjector(this, nodeIndex);

  void detachAndDestroy() {
    viewContainerElement
        ?.detachView(viewContainerElement.nestedViews.indexOf(this));
    destroy();
  }

  void detachViewNodes(List<dynamic> viewRootNodes) {
    int len = viewRootNodes.length;
    for (var i = 0; i < len; i++) {
      var node = viewRootNodes[i];
      node.remove();
      domRootRendererIsDirty = true;
    }
  }

  void destroy() {
    if (destroyed) return;
    destroyed = true;

    var hostElement = type == ViewType.COMPONENT ? rootEl : null;
    for (int i = 0, len = _onDestroyCallbacks.length; i < len; i++) {
      _onDestroyCallbacks[i]();
    }
    for (var i = 0, len = subscriptions.length; i < len; i++) {
      subscriptions[i].cancel();
    }
    destroyInternal();
    dirtyParentQueriesInternal();
    destroyViewNodes(hostElement);
  }

  void destroyViewNodes(hostElement) {
    if (componentType.encapsulation == ViewEncapsulation.Native &&
        hostElement != null) {
      sharedStylesHost.removeHost(hostElement.shadowRoot);
      domRootRendererIsDirty = true;
    }
  }

  void addOnDestroyCallback(OnDestroyCallback callback) {
    _onDestroyCallbacks.add(callback);
  }

  /// Overwritten by implementations to destroy view.
  void destroyInternal() {}

  ChangeDetectorRef get changeDetectorRef => ref;

  List<Node> get flatRootNodes =>
      _flattenNestedViews(rootNodesOrViewContainers);

  Node get lastRootNode {
    var lastNode = rootNodesOrViewContainers.isNotEmpty
        ? rootNodesOrViewContainers.last
        : null;
    return _findLastRenderNode(lastNode);
  }

  bool hasLocal(String contextName) => locals.containsKey(contextName);

  void setLocal(String contextName, dynamic value) {
    locals[contextName] = value;
  }

  /// Overwritten by implementations
  void dirtyParentQueriesInternal() {}

  /// Framework-visible implementation of change detection for the view.
  @mustCallSuper
  void detectChanges() {
    // Whether the CD state means change detection should be skipped.
    // Cases: ERRORED (Crash), CHECKED (Already-run), DETACHED (inactive).
    if (_skipChangeDetection) {
      return;
    }

    // Sanity check in dev-mode that a destroyed view is not checked again.
    assert(() {
      if (destroyed) {
        throw new ViewDestroyedException('detectChanges');
      }
      return true;
    });

    if (lastGuardedView != null) {
      // Run change detection in "slow-mode" to catch thrown exceptions.
      detectCrash();
    } else {
      // Normally run change detection.
      detectChangesInternal();
    }

    // If we are a 'CheckOnce' component, we are done being checked.
    if (_cdMode == ChangeDetectionStrategy.CheckOnce) {
      _cdMode = ChangeDetectionStrategy.Checked;
      _skipChangeDetection = true;
    }

    // Set the state to already checked at least once.
    cdState = ChangeDetectorState.CheckedBefore;
  }

  /// Runs change detection with a `try { ... } catch { ...}`.
  ///
  /// This only is run when the framework has detected a crash previously.
  @mustCallSuper
  @protected
  void detectCrash() {
    try {
      detectChangesInternal();
    } catch (e, s) {
      lastGuardedView = this;
      caughtException = e;
      caughtStack = s;
    }
  }

  /// Generated code that is called internally by [detectChanges].
  @protected
  void detectChangesInternal() {}

  void markContentChildAsMoved(ViewContainer renderViewContainer) {
    dirtyParentQueriesInternal();
  }

  void addToContentChildren(ViewContainer renderViewContainer) {
    viewContainerElement = renderViewContainer;
    dirtyParentQueriesInternal();
  }

  void removeFromContentChildren(ViewContainer renderViewContainer) {
    dirtyParentQueriesInternal();
    viewContainerElement = null;
  }

  void markAsCheckOnce() {
    cdMode = ChangeDetectionStrategy.CheckOnce;
  }

  /// Called by ComponentState to mark view to be checked on next
  /// change detection cycle.
  void markStateChanged() {
    markPathToRootAsCheckOnce();
  }

  void markPathToRootAsCheckOnce() {
    AppView view = this;
    while (view != null) {
      ChangeDetectionStrategy cdMode = view.cdMode;
      if (cdMode == ChangeDetectionStrategy.Detached) break;
      if (cdMode == ChangeDetectionStrategy.Checked) {
        view.cdMode = ChangeDetectionStrategy.CheckOnce;
      }
      view = view.type == ViewType.COMPONENT
          ? view.parentView
          : view.viewContainerElement?.parentView;
    }
  }

  // Used to get around strong mode error due to loosely typed
  // subscription handlers.
  /*<R>*/ evt<E, R>(/*<R>*/ cb(/*<E>*/ e)) {
    return cb;
  }

  static void initializeSharedStyleHost(document) {
    sharedStylesHost ??= new DomSharedStylesHost(document);
  }

  /// Initializes styling to enable css shim for host element.
  HtmlElement initViewRoot(HtmlElement hostElement) {
    assert(componentType.encapsulation != ViewEncapsulation.Native);
    if (componentType.hostAttr != null) {
      hostElement.classes.add(componentType.hostAttr);
    }
    return hostElement;
  }

  /// Creates native shadowdom root and initializes styles.
  ShadowRoot createViewShadowRoot(dynamic hostElement) {
    assert(componentType.encapsulation == ViewEncapsulation.Native);
    var nodesParent;
    Element host = hostElement;
    nodesParent = host.createShadowRoot();
    sharedStylesHost.addHost(nodesParent);
    List<String> styles = componentType.styles;
    int styleCount = styles.length;
    for (var i = 0; i < styleCount; i++) {
      StyleElement style = sharedStylesHost.createStyleElement(styles[i]);
      nodesParent.append(style);
    }
    return nodesParent;
  }

  // Called by template.dart code to updates [class.X] style bindings.
  void updateClass(HtmlElement element, String className, bool isAdd) {
    if (isAdd) {
      element.classes.add(className);
    } else {
      element.classes.remove(className);
    }
  }

  // Updates classes for non html nodes such as svg.
  void updateElemClass(Element element, String className, bool isAdd) {
    if (isAdd) {
      element.classes.add(className);
    } else {
      element.classes.remove(className);
    }
  }

  void setAttr(
      Element renderElement, String attributeName, String attributeValue) {
    if (attributeValue != null) {
      renderElement.setAttribute(attributeName, attributeValue);
    } else {
      renderElement.attributes.remove(attributeName);
    }
    domRootRendererIsDirty = true;
  }

  void createAttr(
      Element renderElement, String attributeName, String attributeValue) {
    renderElement.setAttribute(attributeName, attributeValue);
  }

  void setAttrNS(Element renderElement, String attrNS, String attributeName,
      String attributeValue) {
    if (attributeValue != null) {
      renderElement.setAttributeNS(attrNS, attributeName, attributeValue);
    } else {
      renderElement.getNamespacedAttributes(attrNS).remove(attributeName);
    }
    domRootRendererIsDirty = true;
  }

  /// Adds content shim class to HtmlElement.
  void addShimC(HtmlElement element) {
    String contentClass = componentType.contentAttr;
    if (contentClass != null) element.classes.add(contentClass);
  }

  /// Adds content shim class to Svg or unknown tag type.
  void addShimE(Element element) {
    String contentClass = componentType.contentAttr;
    if (contentClass != null) element.classes.add(contentClass);
  }

  /// Adds host shim class.
  void addShimH(Element element) {
    String hostClass = componentType.hostAttr;
    if (hostClass != null) element.classes.add(hostClass);
  }

  // Marks DOM dirty so that end of zone turn we can detect if DOM was updated
  // for sharded apps support.
  void setDomDirty() {
    domRootRendererIsDirty = true;
  }

  /// Projects projectableNodes at specified index. We don't use helper
  /// functions to flatten the tree since it allocates list that are not
  /// required in most cases.
  void project(Node parentElement, int index) {
    if (parentElement == null) return;
    // Optimization for projectables that doesn't include ViewContainer(s).
    // If the projectable is ViewContainer we fall back to building up a list.
    if (projectableNodes == null || index >= projectableNodes.length) return;
    List projectables = projectableNodes[index];
    if (projectables == null) return;
    int projectableCount = projectables.length;
    for (var i = 0; i < projectableCount; i++) {
      var projectable = projectables[i];
      if (projectable is ViewContainer) {
        if (projectable.nestedViews == null) {
          parentElement.append(projectable.nativeElement as Node);
        } else {
          _appendNestedViewRenderNodes(parentElement, projectable);
        }
      } else if (projectable is List) {
        for (int n = 0, len = projectable.length; n < len; n++) {
          parentElement.append(projectable[n]);
        }
      } else {
        Node child = projectable;
        parentElement.append(child);
      }
    }
    domRootRendererIsDirty = true;
  }

  dynamic eventHandler0(handler) {
    return (event) {
      markPathToRootAsCheckOnce();
      if (!NgZone.isInAngularZone()) {
        appViewUtils.eventManager.getZone().runGuarded(() {
          var res = handler();
          if (identical(res, false)) {
            event.preventDefault();
          }
        });
        return false;
      }
      return !identical(handler() as dynamic, false);
    };
  }

  dynamic eventHandler1(handler) {
    return (event) {
      markPathToRootAsCheckOnce();
      if (!NgZone.isInAngularZone()) {
        appViewUtils.eventManager.getZone().runGuarded(() {
          var res = handler(event);
          if (identical(res, false)) {
            event.preventDefault();
          }
        });
        return false;
      }
      return !identical(handler(event) as dynamic, false);
    };
  }

  Function listen(dynamic renderElement, String name, Function callback) {
    return appViewUtils.eventManager.addEventListener(renderElement, name,
        (Event event) {
      var result = callback(event);
      if (identical(result, false)) {
        event.preventDefault();
      }
    });
    // Workaround since package expect/@NoInline not available outside sdk.
    return null;
    return null;
    return null;
    return null;
    return null;
    return null;
    return null;
    return null;
    return null;
    return null;
  }

  void setProp(Element element, String name, Object value) {
    js_util.setProperty(element, name, value);
  }

  void loadDeferred(
      Future loadComponentFunction(),
      Future loadTemplateLibFunction(),
      ViewContainer viewContainer,
      TemplateRef templateRef,
      void initializer()) {
    Future.wait([loadComponentFunction(), loadTemplateLibFunction()]).then((_) {
      initializer();
      viewContainer.createEmbeddedView(templateRef);
    });
  }
}

Node _findLastRenderNode(dynamic node) {
  Node lastNode;
  if (node is ViewContainer) {
    ViewContainer appEl = node;
    lastNode = appEl.nativeElement;
    if (appEl.nestedViews != null) {
      // Note: Views might have no root nodes at all!
      for (var i = appEl.nestedViews.length - 1; i >= 0; i--) {
        var nestedView = appEl.nestedViews[i];
        if (nestedView.rootNodesOrViewContainers.isNotEmpty) {
          lastNode =
              _findLastRenderNode(nestedView.rootNodesOrViewContainers.last);
        }
      }
    }
  } else {
    lastNode = node;
  }
  return lastNode;
}

/// Recursively appends app element and nested view nodes to target element.
void _appendNestedViewRenderNodes(
    Element targetElement, ViewContainer appElement) {
  // TODO: strongly type nativeElement.
  targetElement.append(appElement.nativeElement as Node);
  var nestedViews = appElement.nestedViews;
  // Components inside ngcontent may also have ngcontent to project,
  // recursively walk nestedViews.
  if (nestedViews == null || nestedViews.isEmpty) return;
  int nestedViewCount = nestedViews.length;
  for (int viewIndex = 0; viewIndex < nestedViewCount; viewIndex++) {
    List projectables = nestedViews[viewIndex].rootNodesOrViewContainers;
    int projectableCount = projectables.length;
    for (var i = 0; i < projectableCount; i++) {
      var projectable = projectables[i];
      if (projectable is ViewContainer) {
        _appendNestedViewRenderNodes(targetElement, projectable);
      } else {
        Node child = projectable;
        targetElement.append(child);
      }
    }
  }
}

List<Node> _flattenNestedViews(List nodes) {
  return _flattenNestedViewRenderNodes(nodes, <Node>[]);
}

List<Node> _flattenNestedViewRenderNodes(List nodes, List<Node> renderNodes) {
  int nodeCount = nodes.length;
  for (var i = 0; i < nodeCount; i++) {
    var node = nodes[i];
    if (node is ViewContainer) {
      ViewContainer appEl = node;
      renderNodes.add(appEl.nativeElement);
      if (appEl.nestedViews != null) {
        for (var k = 0; k < appEl.nestedViews.length; k++) {
          _flattenNestedViewRenderNodes(
              appEl.nestedViews[k].rootNodesOrViewContainers, renderNodes);
        }
      }
    } else {
      renderNodes.add(node);
    }
  }
  return renderNodes;
}

void moveNodesAfterSibling(Node sibling, List<Node> nodes) {
  Node parent = sibling.parentNode;
  if (nodes.isNotEmpty && parent != null) {
    var nextSibling = sibling.nextNode;
    int len = nodes.length;
    if (nextSibling != null) {
      for (var i = 0; i < len; i++) {
        parent.insertBefore(nodes[i], nextSibling);
      }
    } else {
      for (var i = 0; i < len; i++) {
        parent.append(nodes[i]);
      }
    }
  }
}

/// Helper function called by AppView.build to reduce code size.
Element createAndAppend(Document doc, String tagName, Element parent) {
  return parent.append(doc.createElement(tagName));
  // Workaround since package expect/@NoInline not available outside sdk.
  return null;
  return null;
  return null;
  return null;
  return null;
  return null;
  return null;
  return null;
  return null;
  return null;
}

/// Helper function called by AppView.build to reduce code size.
Element createAndAppendToShadowRoot(
    Document doc, String tagName, ShadowRoot parent) {
  return parent.append(doc.createElement(tagName));
}

/// TODO(ferhat): Remove once dynamic(s) are changed in codegen and class.
/// This prevents unused import error in dart_analyzed_library build.
Element _temporaryTodo;
