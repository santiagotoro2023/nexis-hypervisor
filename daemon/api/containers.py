from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

import db
from core import lxc_manager as lxc

router = APIRouter()


class CreateContainer(BaseModel):
    name: str
    template: str = 'debian'
    vcpus: int = 1
    memory_mb: int = 512
    disk_gb: int = 8
    password: str = ''


@router.get('')
def list_containers():
    return lxc.list_containers()


@router.get('/templates')
def list_templates():
    return {'templates': lxc.list_templates()}


@router.post('')
def create_container(req: CreateContainer):
    try:
        lxc.create_container(req.name, req.template, req.vcpus, req.memory_mb, req.disk_gb, req.password)
        db.log_action('container.create', req.name)
        return lxc.get_container(req.name)
    except Exception as e:
        raise HTTPException(400, str(e))


@router.get('/{ct_id}')
def get_container(ct_id: str):
    try:
        return lxc.get_container(ct_id)
    except ValueError as e:
        raise HTTPException(404, str(e))


@router.post('/{ct_id}/start')
def start(ct_id: str):
    try:
        lxc.start_container(ct_id)
        db.log_action('container.start', ct_id)
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))


@router.post('/{ct_id}/stop')
def stop(ct_id: str):
    try:
        lxc.stop_container(ct_id)
        db.log_action('container.stop', ct_id)
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))


@router.post('/{ct_id}/restart')
def restart(ct_id: str):
    try:
        lxc.restart_container(ct_id)
        db.log_action('container.restart', ct_id)
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))


@router.delete('/{ct_id}')
def delete(ct_id: str):
    try:
        lxc.delete_container(ct_id)
        db.log_action('container.delete', ct_id)
        return {'ok': True}
    except Exception as e:
        raise HTTPException(400, str(e))
